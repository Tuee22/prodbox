{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsSesStack
  ( AwsSesStackSnapshot (..)
  , AwsSesResource (..)
  , AwsSesPresenceInventory (..)
  , AwsSesCheckpointSnapshot (..)
  , AwsSesPresenceProbe (..)
  , AwsSesTargetSelection
  , AwsSesLifecycleAuthorityAuthentication
  , awsSesStackName
  , awsSesLegacyPulumiBackend
  , awsSesPresenceInventoryComplete
  , awsSesTargetSelectionForSink
  , awsSesTargetSesSmtpSink
  , defaultAwsSesTargetSelection
  , mkAwsSesTargetSelection
  , classifyAwsSesPresenceOutput
  , destroySummaryFromStackRemove
  , observeAwsSesCheckpoint
  , observeAwsSesCheckpointWithAuthentication
  , ensureAwsSesStackResources
  , ensureAwsSesStackResourcesWithAuthentication
  , destroyAwsSesStack
  , destroyAwsSesStackWithAuthentication
  , destroyAwsSesProviderResourcesWithCredentials
  , destroyAwsSesProviderResourcesWithCredentialsAndAuthentication
  , observeAwsSesProviderResourcesWithCredentials
  , observeAwsSesProviderResourcesWithCredentialsAndAuthentication
  , awsSesProviderPulumiResourceUrns
  , awsSesSmtpPulumiResourceUrns
  , parseAwsSesPulumiResourceUrns
  , awsSesStackResidueStatus
  , migrateAwsSesStackBackend
  , migrateAwsSesStackBackendWithAuthentication
  , renderAwsSesStackReport
  , parseAwsSesStackFromOutputs
  )
where

import Control.Monad (foldM, unless, when)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (isInfixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.CLI.Interactive
  ( awsSesMigrateBackendGuard
  , requireInteractiveTty
  )
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutputLine
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthentication
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchAuthenticatedProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack
  ( awsEksCanonicalClusterName
  , pulumiAwsProviderEnv
  )
import Prodbox.Infra.LongLivedPulumiBackend
  ( loadAdminAwsCredentials
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrlEither
  , purgeRemainingVersions
  )
import Prodbox.Infra.MinioBackend
  ( pulumiBackendLoginTimeoutSeconds
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , TargetClusterSecretSink
  , checkpointAuthorityClusterId
  , mkTargetClusterSecretSink
  , targetSecretSinkIdentity
  )
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent
      ( ReconcileSesCaptureBucket
      , ReconcileSesDkim
      , ReconcileSesDns
      , ReconcileSesReceiptRules
      , ReconcileSesSendingIdentity
      )
  , mkSesBucketRef
  , mkSesDnsRef
  , mkSesIdentityRef
  , mkSesRuleSetRef
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.TargetCommitIntent
  ( RegisteredTargetSet
  , mkRegisteredTargetSet
  , registeredTargetByIdentity
  )
import Prodbox.Pulumi.EncryptedBackend
  ( CheckpointObservability (..)
  , EncryptedBackendError
  , LegacyPulumiBackend (..)
  , PulumiStackRef (..)
  , observeStackCheckpoint
  , renderEncryptedBackendError
  , withDecryptedStackEnvironment
  , withMigratedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
import Prodbox.Ses.Readiness
  ( sesCaptureKeyPrefix
  , sesCaptureReadinessKey
  , sesInboundMxPriority
  , sesInboundMxTarget
  , sesReceiveRuleName
  , sesReceiveRuleSetName
  )
import Prodbox.Settings
  ( ConfigFile
  , Credentials (..)
  , PulumiStateBackendSection
  , Route53Section (..)
  , SesSection (..)
  , loadConfigFile
  , pulumi_state_backend
  , route53
  , ses
  , validateAwsBootstrapConfig
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Text.Read (readMaybe)

awsSesStackName :: String
awsSesStackName = "aws-ses"

awsSesPulumiStackRef :: PulumiStackRef
awsSesPulumiStackRef =
  PulumiStackRef "prodbox-aws-ses" (Text.pack awsSesStackName)

awsSesPulumiProjectDir :: FilePath -> FilePath
awsSesPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-ses"

sesSmtpUserName :: String
sesSmtpUserName = "prodbox-ses-smtp"

-- | Sprint 4.16 typed residue status. Delegates to the live
-- @pulumi stack ls --json@ source-of-truth query against the
-- long-lived S3 backend through 'Prodbox.Lifecycle.LiveResidue'.
-- Long-lived semantics: an unreachable S3 backend is treated as
-- still-present (refusal) because the operator cannot prove the
-- stack is gone.
awsSesStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsSesStackResidueStatus = LiveResidue.queryAwsSesResidueStatus

data AwsSesStackSnapshot = AwsSesStackSnapshot
  { sesSnapshotStackName :: String
  , sesSnapshotBackendBucket :: String
  , sesSnapshotAwsRegion :: String
  , sesSnapshotSendingDomain :: String
  , sesSnapshotReceiveSubdomain :: String
  , sesSnapshotReceiveSubdomainMxFqdn :: String
  , sesSnapshotReceiveSubdomainMxPriority :: Int
  , sesSnapshotReceiveSubdomainMxTarget :: String
  , sesSnapshotReceiveRuleSetName :: String
  , sesSnapshotReceiveRuleName :: String
  , sesSnapshotCaptureBucketName :: String
  , sesSnapshotCaptureBucketArn :: String
  , sesSnapshotCaptureBucketKeyPrefix :: String
  , sesSnapshotCaptureReadinessKey :: String
  }
  deriving (Eq, Show)

-- | Finite fixed-name resources used by checkpoint import/repair. This is an
-- authoritative AWS inventory, not a projection of Pulumi state. The SMTP IAM
-- member remains only for compatibility observation of pre-cutover state; it
-- is not part of the Provider desired-present inventory.
data AwsSesResource
  = AwsSesCaptureBucket
  | AwsSesCaptureReadinessObject
  | AwsSesSmtpIamUser
  | AwsSesReceiveRuleSet
  | AwsSesReceiveRule
  deriving (Eq, Ord, Show)

data AwsSesPresenceInventory = AwsSesPresenceInventory
  { awsSesPresentResources :: ![AwsSesResource]
  }
  deriving (Eq, Show)

awsSesPresenceInventoryComplete :: AwsSesPresenceInventory -> Bool
awsSesPresenceInventoryComplete inventory =
  sort (awsSesPresentResources inventory)
    == sort
      [ AwsSesCaptureBucket
      , AwsSesCaptureReadinessObject
      , AwsSesReceiveRuleSet
      , AwsSesReceiveRule
      ]

-- | One selected target plus the complete finite set a successor must be able
-- to reason about.  The selected sink must be byte-for-byte the registered
-- sink for its identity; coordinate substitution is therefore rejected before
-- any target intent is prepared. Transport is not part of this value.
data AwsSesTargetSelection = AwsSesTargetSelection
  { awsSesRegisteredTargets :: !RegisteredTargetSet
  , awsSesSelectedTarget :: !TargetClusterSecretSink
  }
  deriving (Eq, Show)

mkAwsSesTargetSelection
  :: RegisteredTargetSet
  -> TargetClusterSecretSink
  -> Either String AwsSesTargetSelection
mkAwsSesTargetSelection registered selected =
  case registeredTargetByIdentity registered (targetSecretSinkIdentity selected) of
    Just exact
      | exact == selected ->
          Right
            AwsSesTargetSelection
              { awsSesRegisteredTargets = registered
              , awsSesSelectedTarget = selected
              }
    _ -> Left "selected SES target sink is not the exact registered sink for its identity"

-- | Operator-default target selection. The retained home Target Agent identity
-- is selected; its authenticated transport is supplied independently.
defaultAwsSesTargetSelection
  :: LongLivedCheckpointAuthority -> Either String AwsSesTargetSelection
defaultAwsSesTargetSelection authority = do
  home <- awsSesHomeTargetSink authority
  awsSesTargetSelectionForSink authority home

-- | Construct the complete, stable SES target registry around one explicitly
-- selected sink.  The retained authority always defines the exact home sink.
-- A home selection must match that sink byte-for-byte; an AWS selection must
-- use the canonical EKS identity and SMTP secret coordinate. No transport URL
-- is part of either coordinate.
awsSesTargetSelectionForSink
  :: LongLivedCheckpointAuthority
  -> TargetClusterSecretSink
  -> Either String AwsSesTargetSelection
awsSesTargetSelectionForSink authority selected = do
  home <- awsSesHomeTargetSink authority
  awsTarget <- awsSesTargetSesSmtpSink (Text.pack awsEksCanonicalClusterName)
  let selectedIdentity = targetSecretSinkIdentity selected
      homeIdentity = targetSecretSinkIdentity home
      awsIdentity = Text.pack awsEksCanonicalClusterName
  if homeIdentity == awsIdentity
    then
      Left
        "retained SES authority identity collides with the canonical AWS EKS target identity"
    else
      if selectedIdentity == homeIdentity
        then do
          if selected == home
            then pure ()
            else
              Left
                "selected SES home target must exactly match the retained authority sink"
          registered <- first show (mkRegisteredTargetSet 2 [home, awsTarget])
          mkAwsSesTargetSelection registered home
        else
          if selectedIdentity == awsIdentity
            then do
              canonicalAws <- awsSesTargetSesSmtpSink awsIdentity
              if selected == canonicalAws
                then pure ()
                else
                  Left
                    "selected SES AWS target must use the canonical SMTP secret coordinate"
              registered <- first show (mkRegisteredTargetSet 2 [home, canonicalAws])
              mkAwsSesTargetSelection registered canonicalAws
            else
              Left
                "selected SES target identity is neither the retained home authority nor canonical AWS EKS"

awsSesHomeTargetSink
  :: LongLivedCheckpointAuthority -> Either String TargetClusterSecretSink
awsSesHomeTargetSink authority =
  awsSesTargetSesSmtpSink (checkpointAuthorityClusterId authority)

-- | Compile the exact @TargetSesSmtp@ Vault lane for a Target Agent identity.
-- Endpoint discovery and request authentication belong to the client binding.
awsSesTargetSesSmtpSink :: Text.Text -> Either String TargetClusterSecretSink
awsSesTargetSesSmtpSink identity =
  first show $
    mkTargetClusterSecretSink
      identity
      "secret"
      "keycloak/smtp"

-- | Evidence that the retained Model-B checkpoint is a valid Pulumi
-- checkpoint for the canonical stack. The checkpoint bytes remain opaque and
-- are never copied into plan data.
data AwsSesCheckpointSnapshot = AwsSesCheckpointSnapshot
  { awsSesCheckpointStackName :: !String
  }
  deriving (Eq, Show)

-- | Typed live AWS probe. Each constructor owns its exact not-found error
-- vocabulary; every other non-zero result is unobservable, never absent.
data AwsSesPresenceProbe
  = AwsSesCaptureBucketProbe !String
  | AwsSesCaptureReadinessObjectProbe !String
  | AwsSesSmtpIamUserProbe
  | AwsSesReceiveRuleSetProbe
  | AwsSesReceiveRuleProbe
  deriving (Eq, Show)

data AwsSesStackConfig = AwsSesStackConfig
  { sesStackParentZoneId :: String
  , sesStackSenderDomain :: String
  , sesStackReceiveSubdomain :: String
  , sesStackCaptureBucket :: String
  , sesStackAwsRegion :: String
  }
  deriving (Eq, Show)

awsSesPresenceProbeOperation :: AwsSesPresenceProbe -> String
awsSesPresenceProbeOperation probe =
  "aws " ++ unwords (awsSesPresenceProbeArguments probe)

awsSesPresenceProbeArguments :: AwsSesPresenceProbe -> [String]
awsSesPresenceProbeArguments probe = case probe of
  AwsSesCaptureBucketProbe bucketName ->
    ["s3api", "head-bucket", "--bucket", bucketName]
  AwsSesCaptureReadinessObjectProbe bucketName ->
    [ "s3api"
    , "head-object"
    , "--bucket"
    , bucketName
    , "--key"
    , sesCaptureReadinessKey
    , "--output"
    , "json"
    ]
  AwsSesSmtpIamUserProbe ->
    ["iam", "get-user", "--user-name", sesSmtpUserName, "--output", "json"]
  AwsSesReceiveRuleSetProbe ->
    [ "ses"
    , "describe-receipt-rule-set"
    , "--rule-set-name"
    , sesReceiveRuleSetName
    , "--output"
    , "json"
    ]
  AwsSesReceiveRuleProbe ->
    [ "ses"
    , "describe-receipt-rule"
    , "--rule-set-name"
    , sesReceiveRuleSetName
    , "--rule-name"
    , sesReceiveRuleName
    , "--output"
    , "json"
    ]

-- | Pure classification of an AWS CLI presence probe. Only the exact
-- service-specific not-found vocabulary maps to 'PresenceAbsent'. Access
-- denial, expired credentials, throttling, transport errors reported by the
-- CLI, and malformed responses all remain 'PresenceUnobservable'.
classifyAwsSesPresenceOutput
  :: AwsSesPresenceProbe -> ProcessOutput -> ResidueStatus.PresenceObservation ()
classifyAwsSesPresenceOutput probe output =
  case processExitCode output of
    ExitSuccess ->
      case validateAwsSesPresenceSuccess probe (processStdout output) of
        Right () -> ResidueStatus.PresencePresent ()
        Left validationFailure ->
          ResidueStatus.PresenceUnobservable
            ResidueStatus.ObservationFailure
              { ResidueStatus.observationFailureOperation = awsSesPresenceProbeOperation probe
              , ResidueStatus.observationFailureDetail =
                  "successful AWS response could not be classified: " ++ validationFailure
              }
    ExitFailure _
      | awsSesProbeReportsNotFound probe detail -> ResidueStatus.PresenceAbsent
      | otherwise ->
          ResidueStatus.PresenceUnobservable
            ResidueStatus.ObservationFailure
              { ResidueStatus.observationFailureOperation = awsSesPresenceProbeOperation probe
              , ResidueStatus.observationFailureDetail = detail
              }
 where
  detail = renderProcessDetail output

validateAwsSesPresenceSuccess :: AwsSesPresenceProbe -> String -> Either String ()
validateAwsSesPresenceSuccess probe stdout = case probe of
  AwsSesCaptureBucketProbe _ -> Right ()
  AwsSesCaptureReadinessObjectProbe _ -> validateAwsJsonObject stdout
  AwsSesSmtpIamUserProbe ->
    validateNestedAwsName "User" "UserName" sesSmtpUserName stdout
  AwsSesReceiveRuleSetProbe ->
    validateNestedAwsName "Metadata" "Name" sesReceiveRuleSetName stdout
  AwsSesReceiveRuleProbe ->
    validateNestedAwsName "Rule" "Name" sesReceiveRuleName stdout

validateAwsJsonObject :: String -> Either String ()
validateAwsJsonObject stdout = do
  value <- eitherDecode (BL8.pack stdout)
  case value of
    Object _ -> Right ()
    _ -> Left "top-level value is not a JSON object"

validateNestedAwsName
  :: String -> String -> String -> String -> Either String ()
validateNestedAwsName objectKey nameKey expectedName stdout = do
  value <- eitherDecode (BL8.pack stdout)
  objectValue <- case value of
    Object obj -> Right obj
    _ -> Left "top-level value is not a JSON object"
  nestedValue <-
    case KeyMap.lookup (Key.fromString objectKey) objectValue of
      Just (Object nested) -> Right nested
      _ -> Left ("missing object field '" ++ objectKey ++ "'")
  actualName <-
    case KeyMap.lookup (Key.fromString nameKey) nestedValue of
      Just (String valueText) -> Right (Text.unpack valueText)
      _ -> Left ("missing string field '" ++ objectKey ++ "." ++ nameKey ++ "'")
  if actualName == expectedName
    then Right ()
    else
      Left
        ( "field '"
            ++ objectKey
            ++ "."
            ++ nameKey
            ++ "' named '"
            ++ actualName
            ++ "', expected '"
            ++ expectedName
            ++ "'"
        )

awsSesProbeReportsNotFound :: AwsSesPresenceProbe -> String -> Bool
awsSesProbeReportsNotFound probe rawDetail =
  any (`isInfixOf` normalized) expectedMarkers
 where
  normalized = map toLower rawDetail
  expectedMarkers = case probe of
    AwsSesCaptureBucketProbe _ -> ["nosuchbucket", "(404)", "status code: 404"]
    AwsSesCaptureReadinessObjectProbe _ ->
      ["nosuchkey", "nosuchbucket", "(404)", "status code: 404"]
    AwsSesSmtpIamUserProbe -> ["nosuchentity"]
    AwsSesReceiveRuleSetProbe -> ["rulesetdoesnotexist"]
    AwsSesReceiveRuleProbe -> ["ruledoesnotexist"]

-- | Production Model-B checkpoint observation. Empty objects are corrupt for
-- desired-present repair (they were positively observed but are not usable),
-- while only a missing object becomes 'CheckpointMissing'.
observeAwsSesCheckpoint
  :: FilePath -> IO (ResidueStatus.CheckpointObservation AwsSesCheckpointSnapshot)
observeAwsSesCheckpoint repoRoot = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> observeAwsSesCheckpointWithAuthentication authentication repoRoot)
  pure $ case authenticated of
    Left err ->
      checkpointObservationFailure
        "authenticate aws-ses checkpoint observation"
        (renderLifecycleAuthorityAuthenticationError err)
    Right observation -> observation

observeAwsSesCheckpointWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO (ResidueStatus.CheckpointObservation AwsSesCheckpointSnapshot)
observeAwsSesCheckpointWithAuthentication authentication repoRoot = do
  observed <- observeStackCheckpoint authentication repoRoot awsSesPulumiStackRef
  pure (awsSesCheckpointObservationFromAuthorityResult observed)

awsSesCheckpointObservationFromAuthorityResult
  :: Either EncryptedBackendError CheckpointObservability
  -> ResidueStatus.CheckpointObservation AwsSesCheckpointSnapshot
awsSesCheckpointObservationFromAuthorityResult observed =
  case observed of
    Left err ->
      checkpointObservationFailure
        "observe registered aws-ses checkpoint"
        (renderEncryptedBackendError err)
    Right observability -> awsSesCheckpointObservationFromObservability observability

awsSesCheckpointObservationFromObservability
  :: CheckpointObservability
  -> ResidueStatus.CheckpointObservation AwsSesCheckpointSnapshot
awsSesCheckpointObservationFromObservability observability = case observability of
  CheckpointAbsent -> ResidueStatus.CheckpointMissing
  CheckpointEmpty -> corruptCheckpoint "checkpoint object is empty"
  CheckpointCorrupt detail -> corruptCheckpoint detail
  CheckpointPresent ->
    ResidueStatus.CheckpointValid
      AwsSesCheckpointSnapshot
        { awsSesCheckpointStackName = awsSesStackName
        }

corruptCheckpoint
  :: String -> ResidueStatus.CheckpointObservation snapshot
corruptCheckpoint detail =
  ResidueStatus.CheckpointCorrupt
    ResidueStatus.CheckpointFailure
      { ResidueStatus.checkpointFailureDetail = detail
      }

checkpointObservationFailure
  :: String -> String -> ResidueStatus.CheckpointObservation snapshot
checkpointObservationFailure operation detail =
  ResidueStatus.CheckpointUnobservable
    ResidueStatus.ObservationFailure
      { ResidueStatus.observationFailureOperation = operation
      , ResidueStatus.observationFailureDetail = detail
      }

renderObservationFailure :: ResidueStatus.ObservationFailure -> String
renderObservationFailure failure =
  ResidueStatus.observationFailureOperation failure
    ++ ": "
    ++ ResidueStatus.observationFailureDetail failure

-- | Sprint 4.18: live source-of-truth read of the @aws-ses@ stack's snapshot
-- from the operator-account long-lived S3 Pulumi backend. Returns 'Nothing'
-- when the stack is absent, the backend is unreachable, or the outputs
-- cannot be parsed — matching the @Maybe@ contract the destroy path
-- previously got from the file cache.
fetchAwsSesStackSnapshotFromBackendWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO (Maybe AwsSesStackSnapshot)
fetchAwsSesStackSnapshotFromBackendWithAuthentication authentication repoRoot = do
  outputsResult <-
    LiveResidue.fetchAwsSesStackOutputsWithAuthentication authentication repoRoot
  pure $ case outputsResult of
    Left _ -> Nothing
    Right outputs -> either (const Nothing) Just (parseAwsSesStackFromOutputs outputs)

-- | Sprint 4.18: decode an 'AwsSesStackSnapshot' record directly from the
-- flat @Map Text Text@ returned by
-- 'Prodbox.Lifecycle.LiveResidue.fetchAwsSesStackOutputs'. Replaces the
-- legacy @.prodbox-state\/aws-ses\/stack-snapshot.json@ file-IO consumer
-- on the destroy and residue paths.
parseAwsSesStackFromOutputs
  :: Map Text.Text Text.Text -> Either String AwsSesStackSnapshot
parseAwsSesStackFromOutputs outputs = do
  backendBucket <- requireMapString outputs "backend_bucket"
  awsRegion <- requireMapString outputs "aws_region"
  sendingDomain <- requireMapString outputs "sending_domain"
  receiveSubdomain <- requireMapString outputs "receive_subdomain"
  receiveSubdomainMxFqdn <- requireMapString outputs "receive_subdomain_mx_fqdn"
  receiveSubdomainMxPriority <- requireMapInt outputs "receive_subdomain_mx_priority"
  receiveSubdomainMxTarget <- requireMapString outputs "receive_subdomain_mx_target"
  receiveRuleSetName <- requireMapString outputs "receive_rule_set_name"
  receiveRuleName <- requireMapString outputs "receive_rule_name"
  captureBucketName <- requireMapString outputs "capture_bucket_name"
  captureBucketArn <- requireMapString outputs "capture_bucket_arn"
  captureBucketKeyPrefix <- requireMapString outputs "capture_bucket_key_prefix"
  captureReadinessKey <- requireMapString outputs "capture_readiness_key"
  let snapshot =
        AwsSesStackSnapshot
          { sesSnapshotStackName = awsSesStackName
          , sesSnapshotBackendBucket = backendBucket
          , sesSnapshotAwsRegion = awsRegion
          , sesSnapshotSendingDomain = sendingDomain
          , sesSnapshotReceiveSubdomain = receiveSubdomain
          , sesSnapshotReceiveSubdomainMxFqdn = receiveSubdomainMxFqdn
          , sesSnapshotReceiveSubdomainMxPriority = receiveSubdomainMxPriority
          , sesSnapshotReceiveSubdomainMxTarget = receiveSubdomainMxTarget
          , sesSnapshotReceiveRuleSetName = receiveRuleSetName
          , sesSnapshotReceiveRuleName = receiveRuleName
          , sesSnapshotCaptureBucketName = captureBucketName
          , sesSnapshotCaptureBucketArn = captureBucketArn
          , sesSnapshotCaptureBucketKeyPrefix = captureBucketKeyPrefix
          , sesSnapshotCaptureReadinessKey = captureReadinessKey
          }
  validateAwsSesStackSnapshot snapshot

requireMapString :: Map Text.Text Text.Text -> String -> Either String String
requireMapString outputs key =
  case Map.lookup (Text.pack key) outputs of
    Nothing -> Left ("aws-ses Pulumi outputs missing required field '" ++ key ++ "'")
    Just text ->
      let str = Text.unpack text
       in if null str
            then Left ("aws-ses Pulumi outputs field '" ++ key ++ "' is empty")
            else Right str

requireMapInt :: Map Text.Text Text.Text -> String -> Either String Int
requireMapInt outputs key =
  requireIntOutput key =<< requireMapString outputs key

requireIntOutput :: String -> String -> Either String Int
requireIntOutput key raw =
  case readMaybe (Text.unpack (Text.strip (Text.pack raw))) of
    Just value -> Right value
    Nothing -> Left ("aws-ses Pulumi output '" ++ key ++ "' is not an integer")

validateAwsSesStackSnapshot :: AwsSesStackSnapshot -> Either String AwsSesStackSnapshot
validateAwsSesStackSnapshot snapshot = do
  requireExact
    "receive_rule_set_name"
    sesReceiveRuleSetName
    (sesSnapshotReceiveRuleSetName snapshot)
  requireExact "receive_rule_name" sesReceiveRuleName (sesSnapshotReceiveRuleName snapshot)
  requireExact
    "capture_bucket_key_prefix"
    sesCaptureKeyPrefix
    (sesSnapshotCaptureBucketKeyPrefix snapshot)
  requireExact
    "capture_readiness_key"
    sesCaptureReadinessKey
    (sesSnapshotCaptureReadinessKey snapshot)
  requireExact
    "receive_subdomain_mx_priority"
    sesInboundMxPriority
    (sesSnapshotReceiveSubdomainMxPriority snapshot)
  requireExact
    "receive_subdomain_mx_target"
    (sesInboundMxTarget (sesSnapshotAwsRegion snapshot))
    (sesSnapshotReceiveSubdomainMxTarget snapshot)
  Right snapshot
 where
  requireExact :: (Eq value, Show value) => String -> value -> value -> Either String ()
  requireExact key expected actual
    | actual == expected = Right ()
    | otherwise =
        Left
          ( "aws-ses Pulumi output '"
              ++ key
              ++ "' is "
              ++ show actual
              ++ ", expected "
              ++ show expected
          )

renderAwsSesStackReport :: AwsSesStackSnapshot -> Int -> String
renderAwsSesStackReport snapshot objectCount =
  unlines
    ( [ "STACK=" ++ sesSnapshotStackName snapshot
      , "BACKEND_BUCKET=" ++ sesSnapshotBackendBucket snapshot
      , "BACKEND_OBJECT_COUNT=" ++ show objectCount
      , "AWS_REGION=" ++ sesSnapshotAwsRegion snapshot
      , "SENDING_DOMAIN=" ++ sesSnapshotSendingDomain snapshot
      , "RECEIVE_SUBDOMAIN=" ++ sesSnapshotReceiveSubdomain snapshot
      , "RECEIVE_SUBDOMAIN_MX_FQDN=" ++ sesSnapshotReceiveSubdomainMxFqdn snapshot
      , "RECEIVE_SUBDOMAIN_MX_PRIORITY=" ++ show (sesSnapshotReceiveSubdomainMxPriority snapshot)
      , "RECEIVE_SUBDOMAIN_MX_TARGET=" ++ sesSnapshotReceiveSubdomainMxTarget snapshot
      , "RECEIVE_RULE_SET_NAME=" ++ sesSnapshotReceiveRuleSetName snapshot
      , "RECEIVE_RULE_NAME=" ++ sesSnapshotReceiveRuleName snapshot
      , "CAPTURE_BUCKET_NAME=" ++ sesSnapshotCaptureBucketName snapshot
      , "CAPTURE_BUCKET_ARN=" ++ sesSnapshotCaptureBucketArn snapshot
      , "CAPTURE_BUCKET_KEY_PREFIX=" ++ sesSnapshotCaptureBucketKeyPrefix snapshot
      , "CAPTURE_READINESS_KEY=" ++ sesSnapshotCaptureReadinessKey snapshot
      ]
    )

-- | Sprint 7.16: the SES stack's AWS region now comes from the EPHEMERAL admin
-- credential acquired through 'loadAdminAwsCredentials' (test-secrets.dhall's
-- @aws_admin_for_test_simulation@ block, or the interactive prompt), not from a
-- @prodbox.dhall@ field. The production config still supplies the
-- Route 53 zone, sender domain, receive subdomain, and capture bucket.
resolveAwsSesStackConfig :: FilePath -> IO (Either String AwsSesStackConfig)
resolveAwsSesStackConfig repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> pure (Left err)
    Right adminCreds -> resolveAwsSesStackConfigForCredentials repoRoot adminCreds

resolveAwsSesStackConfigForCredentials
  :: FilePath -> Credentials -> IO (Either String AwsSesStackConfig)
resolveAwsSesStackConfigForCredentials repoRoot credentials = do
  configResult <- loadConfigFile repoRoot
  pure $ do
    config <- configResult
    awsSesStackConfigFromConfig
      config
      (Text.unpack (Text.strip (region credentials)))

awsSesStackConfigFromConfig :: ConfigFile -> String -> Either String AwsSesStackConfig
awsSesStackConfigFromConfig config adminRegion = do
  validateAwsBootstrapConfig config
  if null parentZoneId
    then Left "route53.zone_id must be set before provisioning the AWS SES stack"
    else
      if null senderDomainValue
        then Left "ses.sender_domain must be set before provisioning the AWS SES stack"
        else
          if null receiveSubdomainValue
            then
              Left "ses.receive_subdomain must be set before provisioning the AWS SES stack"
            else
              if null captureBucketValue
                then
                  Left "ses.capture_bucket must be set before provisioning the AWS SES stack"
                else
                  if null awsRegionValue
                    then
                      Left
                        "the admin AWS credential region must be set before provisioning the AWS SES stack"
                    else
                      Right
                        AwsSesStackConfig
                          { sesStackParentZoneId = parentZoneId
                          , sesStackSenderDomain = senderDomainValue
                          , sesStackReceiveSubdomain = receiveSubdomainValue
                          , sesStackCaptureBucket = captureBucketValue
                          , sesStackAwsRegion = awsRegionValue
                          }
 where
  parentZoneId = Text.unpack (Text.strip (zone_id (route53 config)))
  sesSection = ses config
  senderDomainValue = Text.unpack (Text.strip (sender_domain sesSection))
  receiveSubdomainValue = Text.unpack (Text.strip (receive_subdomain sesSection))
  captureBucketValue = Text.unpack (Text.strip (capture_bucket sesSection))
  awsRegionValue = adminRegion

syncAwsSesStackConfig :: FilePath -> [(String, String)] -> AwsSesStackConfig -> IO ExitCode
syncAwsSesStackConfig projectDir environment stackConfig =
  foldM runConfigSet ExitSuccess configEntries
 where
  configEntries =
    [ ("senderDomain", sesStackSenderDomain stackConfig)
    , ("receiveSubdomain", sesStackReceiveSubdomain stackConfig)
    , ("captureBucket", sesStackCaptureBucket stackConfig)
    , ("awsRegion", sesStackAwsRegion stackConfig)
    ]

  runConfigSet :: ExitCode -> (String, String) -> IO ExitCode
  runConfigSet failure@(ExitFailure _) _ = pure failure
  runConfigSet ExitSuccess (key, value) =
    runPulumiCommand
      projectDir
      environment
      ["config", "set", "--stack", awsSesStackName, key, value]

-- | Legacy Sprint 4.10 admin-credential build used only as the
-- optional first-touch source for encrypted backend migration. Main
-- Sprint 7.14 reconcile/destroy/migration paths run Pulumi against the
-- encrypted scratch backend instead of handing raw S3 backend
-- credentials to the supported action.
pulumiSesAdminBaseEnv
  :: FilePath
  -> Credentials
  -> PulumiStateBackendSection
  -> IO (Either String [(String, String)])
pulumiSesAdminBaseEnv _repoRoot adminCreds backend =
  case longLivedPulumiBackendUrlEither backend of
    Left err -> pure (Left (longLivedBackendErrorMessage err))
    Right backendUrl -> do
      providerEnv <- pulumiSesProviderBaseEnv adminCreds
      let adminRegion = Text.unpack (region adminCreds)
          sessionTokenEntries = case session_token adminCreds of
            Just token -> [("AWS_SESSION_TOKEN", Text.unpack token)]
            Nothing -> []
      pure
        ( Right
            ( [ ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id adminCreds))
              , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key adminCreds))
              , ("AWS_REGION", adminRegion)
              , ("AWS_DEFAULT_REGION", adminRegion)
              , ("PULUMI_BACKEND_URL", backendUrl)
              , ("PULUMI_CONFIG_PASSPHRASE", "")
              ]
                ++ sessionTokenEntries
                ++ providerEnv
            )
        )

pulumiSesProviderBaseEnv :: Credentials -> IO [(String, String)]
pulumiSesProviderBaseEnv adminCreds = do
  currentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" currentEnv)
      home = maybe "" id (lookup "HOME" currentEnv)
  pure
    ( [ ("AWS_EC2_METADATA_DISABLED", "true")
      , ("PULUMI_SKIP_UPDATE_CHECK", "true")
      , ("PATH", path)
      , ("HOME", home)
      , ("LANG", "C.UTF-8")
      ]
        ++ pulumiAwsProviderEnv adminCreds
    )

withAwsSesEncryptedStackEnvironment
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> FilePath
  -> Credentials
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withAwsSesEncryptedStackEnvironment authentication repoRoot projectDir adminCreds environment action = do
  legacyBackend <- awsSesLegacyPulumiBackend repoRoot projectDir adminCreds
  case legacyBackend of
    Nothing ->
      withDecryptedStackEnvironment authentication repoRoot awsSesPulumiStackRef environment action
    Just legacy ->
      withMigratedDecryptedStackEnvironment
        authentication
        repoRoot
        awsSesPulumiStackRef
        legacy
        environment
        action

awsSesLegacyPulumiBackend
  :: FilePath -> FilePath -> Credentials -> IO (Maybe LegacyPulumiBackend)
awsSesLegacyPulumiBackend repoRoot projectDir adminCreds = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left _ -> pure Nothing
    Right config -> do
      legacyEnvironmentResult <-
        pulumiSesAdminBaseEnv repoRoot adminCreds (pulumi_state_backend config)
      pure $ case legacyEnvironmentResult of
        Left _ -> Nothing
        Right legacyEnvironment ->
          Just (LegacyPulumiBackend projectDir legacyEnvironment (Text.pack awsSesStackName))

pulumiLogin :: FilePath -> [(String, String)] -> IO ExitCode
pulumiLogin projectDir environment = do
  loginResult <- pulumiLoginQuiet projectDir environment
  case loginResult of
    Right () -> pure ExitSuccess
    Left err -> do
      writeDiagnosticLine ("pulumi login failed: " ++ err)
      pure (ExitFailure 1)

pulumiLoginQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiLoginQuiet projectDir environment =
  runPulumiCommandQuiet
    projectDir
    environment
    ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]

data PulumiStackSelectResult
  = PulumiStackSelected
  | PulumiStackMissing
  | PulumiStackSelectFailed String

pulumiStackSelect :: FilePath -> [(String, String)] -> Bool -> IO PulumiStackSelectResult
pulumiStackSelect projectDir environment createIfMissing =
  let arguments =
        ["stack", "select", awsSesStackName]
          ++ ["--create" | createIfMissing]
          -- Sprint 7.23: the scratch file-backend stack uses the `passphrase`
          -- secrets provider (with the empty PULUMI_CONFIG_PASSPHRASE the
          -- scratch env sets), matching the committed `encryptionsalt` in
          -- Pulumi.aws-ses.yaml. The historical `plaintext` value is not a
          -- valid pulumi secrets-provider URL on current pulumi
          -- (`open secrets.Keeper: no scheme in URL "plaintext"`); at-rest
          -- secrecy is provided by the Model-B Vault-Transit envelope, and the
          -- empty-passphrase provider keeps the in-checkpoint secrets pulumi-valid.
          ++ if createIfMissing then ["--secrets-provider", "passphrase"] else []
   in if createIfMissing
        then do
          exitCode <- runPulumiCommand projectDir environment arguments
          pure $ case exitCode of
            ExitSuccess -> PulumiStackSelected
            ExitFailure _ -> PulumiStackSelectFailed "pulumi stack select failed"
        else do
          result <-
            captureSubprocessResult
              Subprocess
                { subprocessPath = "pulumi"
                , subprocessArguments = arguments
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just projectDir
                }
          pure $ case result of
            Failure err -> PulumiStackSelectFailed err
            Success output ->
              case processExitCode output of
                ExitSuccess -> PulumiStackSelected
                ExitFailure _
                  | isMissingPulumiStackError awsSesStackName (renderProcessDetail output) ->
                      PulumiStackMissing
                  | otherwise ->
                      PulumiStackSelectFailed (renderProcessDetail output)

pulumiDestroyQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiDestroyQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["destroy", "--yes", "--stack", awsSesStackName]

pulumiStackRemoveQuiet :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiStackRemoveQuiet projectDir environment force =
  runPulumiCommandQuiet
    projectDir
    environment
    (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsSesStackName])

-- | Compatibility name for the common caller-bound Lifecycle Authority
-- authentication capability. The constructor stays opaque; production callers
-- obtain it only from the explicit host provisioner.
type AwsSesLifecycleAuthorityAuthentication = LifecycleAuthorityAuthentication

runPulumiCommand :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runPulumiCommand projectDir environment arguments = do
  result <-
    runSubprocessStreaming
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  case result of
    Failure err -> do
      writeDiagnosticLine err
      pure (ExitFailure 1)
    Success exitCode -> pure exitCode

runPulumiCommandQuiet :: FilePath -> [(String, String)] -> [String] -> IO (Either String ())
runPulumiCommandQuiet projectDir environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath =
            if isPulumiLoginCommand arguments
              then "timeout"
              else "pulumi"
        , subprocessArguments =
            if isPulumiLoginCommand arguments
              then
                [ "--kill-after=10s"
                , show pulumiBackendLoginTimeoutSeconds
                , "pulumi"
                ]
                  ++ arguments
                  ++ ["--non-interactive"]
              else arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $ case result of
    Failure err -> Left err
    Success output ->
      case processExitCode output of
        ExitSuccess -> Right ()
        ExitFailure 124
          | isPulumiLoginCommand arguments ->
              Left
                ( "timed out after "
                    ++ show pulumiBackendLoginTimeoutSeconds
                    ++ " seconds while running `pulumi login` against the MinIO backend"
                )
        ExitFailure _ -> Left (renderProcessDetail output)

isPulumiLoginCommand :: [String] -> Bool
isPulumiLoginCommand arguments =
  case arguments of
    "login" : _ -> True
    _ -> False

isMissingPulumiStackError :: String -> String -> Bool
isMissingPulumiStackError stackName detail =
  let lowered = map toLower detail
      loweredStackName = map toLower stackName
   in "no stack named" `isInfixOf` lowered
        && loweredStackName `isInfixOf` lowered
        && "found" `isInfixOf` lowered

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse

-- | The supported reconcile acquires the retained authority lease and mints
-- one bounded STS role session for each work stage. Pulumi state is hydrated
-- through the fenced encrypted scratch backend; the legacy long-lived S3
-- backend survives only as an optional first-touch migration source.
ensureAwsSesStackResources :: FilePath -> IO ExitCode
ensureAwsSesStackResources repoRoot = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> ensureAwsSesStackResourcesWithAuthentication authentication repoRoot)
  case authenticated of
    Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
    Right exitCode -> pure exitCode

ensureAwsSesStackResourcesWithAuthentication
  :: AwsSesLifecycleAuthorityAuthentication
  -> FilePath
  -> IO ExitCode
ensureAwsSesStackResourcesWithAuthentication authentication repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult >>= awsSesProviderIntents of
    Left err -> failWith err
    Right intents -> dispatchProviderIntents intents
 where
  dispatchProviderIntents [] = pure ExitSuccess
  dispatchProviderIntents ((label, prefix, intent) : remaining) = do
    result <-
      dispatchAuthenticatedProviderIntentFresh
        authentication
        prefix
        intent
    case result of
      Left err -> failWith (renderProviderCallerError err)
      Right evidence -> do
        writeOutputLine (label ++ Text.unpack evidence)
        dispatchProviderIntents remaining

awsSesProviderIntents
  :: ConfigFile
  -> Either String [(String, Text.Text, ProviderIntent)]
awsSesProviderIntents config = do
  validateAwsBootstrapConfig config
  let sesConfig = ses config
      sender = Text.strip (sender_domain sesConfig)
      recipient = Text.strip (receive_subdomain sesConfig)
      bucketName = Text.strip (capture_bucket sesConfig)
      hostedZoneId = Text.strip (zone_id (route53 config))
  identity <- first show (mkSesIdentityRef sender)
  bucket <- first show (mkSesBucketRef bucketName)
  dns <- first show (mkSesDnsRef hostedZoneId sender recipient)
  rules <-
    first
      show
      ( mkSesRuleSetRef
          (Text.pack sesReceiveRuleSetName)
          recipient
          bucketName
      )
  pure
    [
      ( "AWS SES sending-identity Provider receipt: "
      , "operator-reconcile-ses-identity"
      , ReconcileSesSendingIdentity identity
      )
    ,
      ( "AWS SES DKIM Provider receipt: "
      , "operator-reconcile-ses-dkim"
      , ReconcileSesDkim identity
      )
    ,
      ( "AWS SES DNS Provider receipt: "
      , "operator-reconcile-ses-dns"
      , ReconcileSesDns dns
      )
    ,
      ( "AWS SES capture-bucket Provider receipt: "
      , "operator-reconcile-ses-capture"
      , ReconcileSesCaptureBucket bucket
      )
    ,
      ( "AWS SES receipt-rules Provider receipt: "
      , "operator-reconcile-ses-rules"
      , ReconcileSesReceiptRules rules
      )
    ]

awsCliCredsFromProviderEnv :: [(String, String)] -> [(String, String)]
awsCliCredsFromProviderEnv environment =
  foldr overlay environment providerToAwsCli
 where
  providerToAwsCli =
    [ ("PRODBOX_PULUMI_AWS_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID")
    , ("PRODBOX_PULUMI_AWS_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY")
    , ("PRODBOX_PULUMI_AWS_SESSION_TOKEN", "AWS_SESSION_TOKEN")
    , ("PRODBOX_PULUMI_AWS_REGION", "AWS_REGION")
    , ("PRODBOX_PULUMI_AWS_DEFAULT_REGION", "AWS_DEFAULT_REGION")
    ]
  overlay (fromKey, toKey) env =
    case lookup fromKey env of
      Just value -> (toKey, value) : filter ((/= toKey) . fst) env
      Nothing -> env

destroyAwsSesStack :: FilePath -> Bool -> IO ExitCode
destroyAwsSesStack repoRoot quietOutput = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> destroyAwsSesStackWithAuthentication authentication repoRoot quietOutput)
  case authenticated of
    Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
    Right exitCode -> pure exitCode

destroyAwsSesStackWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Bool
  -> IO ExitCode
destroyAwsSesStackWithAuthentication authentication repoRoot quietOutput = do
  statusResult <- destroyAwsSesStackStatus authentication repoRoot quietOutput
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS SES stack: " ++ status)
      pure ExitSuccess

-- | The exact non-credential resources currently owned by the @aws-ses@
-- Pulumi program.  SMTP IAM and the default provider are deliberately absent.
-- The URNs are stable ownership coordinates rather than display names, so a
-- targeted destroy cannot expand into the later SMTP-IAM graph node.
awsSesProviderPulumiResourceUrns :: [Text.Text]
awsSesProviderPulumiResourceUrns =
  map
    awsSesResourceUrn
    [ ("aws:s3/bucket:Bucket", "captureBucketResource")
    , ("aws:s3/bucketPolicy:BucketPolicy", "captureBucketPolicy")
    , ("aws:s3/bucketObjectv2:BucketObjectv2", "captureReadinessObject")
    , ("aws:ses/domainIdentity:DomainIdentity", "sendingIdentity")
    , ("aws:ses/domainDkim:DomainDkim", "sendingIdentityDkim")
    , ("aws:route53/record:Record", "sendingIdentityVerificationRecord")
    , ("aws:route53/record:Record", "sendingIdentityDkimRecord0")
    , ("aws:route53/record:Record", "sendingIdentityDkimRecord1")
    , ("aws:route53/record:Record", "sendingIdentityDkimRecord2")
    , ("aws:route53/record:Record", "receiveSubdomainMx")
    , ("aws:ses/receiptRuleSet:ReceiptRuleSet", "receiveRuleSet")
    , ("aws:ses/receiptRule:ReceiptRule", "receiveRule")
    , ("aws:ses/activeReceiptRuleSet:ActiveReceiptRuleSet", "receiveActiveRuleSet")
    ]

-- | Compatibility URNs for checkpoints created before SMTP-IAM ownership left
-- Pulumi. They remain observable by the separately typed Admin teardown path;
-- the current Provider program cannot construct either resource. A provider
-- destroy verifies that any such legacy subset is unchanged.
awsSesSmtpPulumiResourceUrns :: [Text.Text]
awsSesSmtpPulumiResourceUrns =
  map
    awsSesResourceUrn
    [ ("aws:iam/user:User", "smtpUser")
    , ("aws:iam/userPolicy:UserPolicy", "smtpUserPolicy")
    ]

awsSesResourceUrn :: (Text.Text, Text.Text) -> Text.Text
awsSesResourceUrn (resourceType, logicalName) =
  "urn:pulumi:"
    <> Text.pack awsSesStackName
    <> "::prodbox-aws-ses::"
    <> resourceType
    <> "::"
    <> logicalName

-- | Decode the exact resource URNs from @pulumi stack export@.  Missing or
-- malformed deployment/resource fields are unobservable, never an empty
-- stack: treating corrupt state as absence would let teardown skip live AWS
-- resources.
parseAwsSesPulumiResourceUrns :: String -> Either String [Text.Text]
parseAwsSesPulumiResourceUrns payload = do
  value <- first ("failed to decode Pulumi stack export: " ++) (eitherDecode (BL8.pack payload))
  deployment <- requireObjectField "deployment" value
  resources <- requireArrayField "resources" deployment
  traverse requireResourceUrn (foldr (:) [] resources)
 where
  requireObjectField field (Object fields) =
    case KeyMap.lookup (Key.fromString field) fields of
      Just (Object objectValue) -> Right objectValue
      _ -> Left ("Pulumi stack export is missing object field '" ++ field ++ "'")
  requireObjectField field _ =
    Left ("Pulumi stack export is missing object field '" ++ field ++ "'")

  requireArrayField field fields =
    case KeyMap.lookup (Key.fromString field) fields of
      Just (Array values) -> Right values
      _ -> Left ("Pulumi stack deployment is missing array field '" ++ field ++ "'")

  requireResourceUrn (Object resource) =
    case KeyMap.lookup (Key.fromString "urn") resource of
      Just (String urn) | not (Text.null (Text.strip urn)) -> Right urn
      _ -> Left "Pulumi stack resource is missing a non-empty urn"
  requireResourceUrn _ = Left "Pulumi stack resource is not an object"

-- | Destroy only the provider family through Pulumi's exact target set. The
-- encrypted checkpoint wrapper persists the resulting target removals, while
-- compatibility SMTP-IAM URNs are compared before/after and may not change.
-- This is intentionally not implemented by relabelling the broad stack destroy.
destroyAwsSesProviderResourcesWithCredentials
  :: FilePath
  -> Credentials
  -> IO (Either String ())
destroyAwsSesProviderResourcesWithCredentials repoRoot credentials = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      ( \authentication ->
          destroyAwsSesProviderResourcesWithCredentialsAndAuthentication
            authentication
            repoRoot
            credentials
      )
  pure $ case authenticated of
    Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
    Right result -> result

destroyAwsSesProviderResourcesWithCredentialsAndAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Credentials
  -> IO (Either String ())
destroyAwsSesProviderResourcesWithCredentialsAndAuthentication authentication repoRoot credentials = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  configResult <- resolveAwsSesStackConfigForCredentials repoRoot credentials
  case configResult of
    Left detail -> pure (Left detail)
    Right stackConfig -> do
      baseEnvironment <- pulumiSesProviderBaseEnv credentials
      result <-
        withAwsSesEncryptedStackEnvironment
          authentication
          repoRoot
          projectDir
          credentials
          baseEnvironment
          (destroyProviderTargets projectDir stackConfig)
      pure (first renderEncryptedBackendError result)

destroyProviderTargets
  :: FilePath
  -> AwsSesStackConfig
  -> [(String, String)]
  -> IO (Either String ())
destroyProviderTargets projectDir stackConfig environment = do
  loginResult <- pulumiLoginQuiet projectDir environment
  case loginResult of
    Left detail -> pure (Left ("pulumi login failed: " ++ detail))
    Right () -> do
      selection <- pulumiStackSelect projectDir environment False
      case selection of
        PulumiStackMissing ->
          pure (Left "aws-ses checkpoint is absent; provider resource absence cannot be proven")
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))
        PulumiStackSelected -> do
          beforeResult <- readAwsSesPulumiResourceUrns projectDir environment
          case beforeResult of
            Left detail -> pure (Left detail)
            Right beforeUrns -> do
              let providerTargets = presentUrns awsSesProviderPulumiResourceUrns beforeUrns
                  smtpBefore = presentUrns awsSesSmtpPulumiResourceUrns beforeUrns
              if null providerTargets
                then pure (Right ())
                else do
                  purgeResult <-
                    if captureBucketUrn `elem` providerTargets
                      then
                        purgeAwsSesCaptureBucket
                          projectDir
                          (awsCliCredsFromProviderEnv environment)
                          (sesStackCaptureBucket stackConfig)
                      else pure (Right ())
                  case purgeResult of
                    Left detail -> pure (Left detail)
                    Right () -> do
                      destroyResult <-
                        runPulumiCommandQuiet
                          projectDir
                          environment
                          ( [ "destroy"
                            , "--yes"
                            , "--stack"
                            , awsSesStackName
                            , "--non-interactive"
                            , "--suppress-outputs"
                            ]
                              ++ concatMap (\urn -> ["--target", Text.unpack urn]) providerTargets
                          )
                      case destroyResult of
                        Left detail -> pure (Left ("provider-only pulumi destroy failed: " ++ detail))
                        Right () -> do
                          afterResult <- readAwsSesPulumiResourceUrns projectDir environment
                          pure $ do
                            afterUrns <- afterResult
                            let providerAfter = presentUrns awsSesProviderPulumiResourceUrns afterUrns
                                smtpAfter = presentUrns awsSesSmtpPulumiResourceUrns afterUrns
                            unless (null providerAfter) $
                              Left
                                ( "provider-only Pulumi read-back still contains targets: "
                                    ++ show providerAfter
                                )
                            when (smtpAfter /= smtpBefore) $
                              Left
                                ( "provider-only Pulumi destroy changed the SMTP IAM family: before="
                                    ++ show smtpBefore
                                    ++ ", after="
                                    ++ show smtpAfter
                                )
                            Right ()
 where
  captureBucketUrn =
    awsSesResourceUrn ("aws:s3/bucket:Bucket", "captureBucketResource")

-- | Read-only target-state observation used after a successful action and on
-- receipt recovery.  A missing/corrupt/unreachable checkpoint is not absence.
observeAwsSesProviderResourcesWithCredentials
  :: FilePath
  -> Credentials
  -> IO ResidueStatus.ResidueStatus
observeAwsSesProviderResourcesWithCredentials repoRoot credentials = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      ( \authentication ->
          observeAwsSesProviderResourcesWithCredentialsAndAuthentication
            authentication
            repoRoot
            credentials
      )
  pure $ case authenticated of
    Left err -> providerUnreachable (renderLifecycleAuthorityAuthenticationError err)
    Right status -> status

observeAwsSesProviderResourcesWithCredentialsAndAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Credentials
  -> IO ResidueStatus.ResidueStatus
observeAwsSesProviderResourcesWithCredentialsAndAuthentication authentication repoRoot credentials = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  baseEnvironment <- pulumiSesProviderBaseEnv credentials
  result <-
    withAwsSesEncryptedStackEnvironment
      authentication
      repoRoot
      projectDir
      credentials
      baseEnvironment
      (observeProviderTargets projectDir)
  pure $ case result of
    Left err -> providerUnreachable (renderEncryptedBackendError err)
    Right status -> status

observeProviderTargets
  :: FilePath
  -> [(String, String)]
  -> IO (Either String ResidueStatus.ResidueStatus)
observeProviderTargets projectDir environment = do
  loginResult <- pulumiLoginQuiet projectDir environment
  case loginResult of
    Left detail -> pure (Left ("pulumi login failed: " ++ detail))
    Right () -> do
      selection <- pulumiStackSelect projectDir environment False
      case selection of
        PulumiStackMissing ->
          pure (Left "aws-ses checkpoint is absent; provider resource absence cannot be proven")
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))
        PulumiStackSelected -> do
          urnResult <- readAwsSesPulumiResourceUrns projectDir environment
          pure $ do
            urns <- urnResult
            let present = presentUrns awsSesProviderPulumiResourceUrns urns
            Right $ case present of
              [] -> ResidueStatus.ResidueAbsent
              _ ->
                ResidueStatus.ResiduePresent
                  ( ResidueStatus.ResidueDetails
                      ("Pulumi checkpoint retains provider targets: " ++ show present)
                      awsSesStackName
                  )

readAwsSesPulumiResourceUrns
  :: FilePath
  -> [(String, String)]
  -> IO (Either String [Text.Text])
readAwsSesPulumiResourceUrns projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["stack", "export", "--stack", awsSesStackName]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $ case result of
    Failure detail -> Left ("failed to start pulumi stack export: " ++ detail)
    Success output -> case processExitCode output of
      ExitFailure code ->
        Left
          ( "pulumi stack export exited with code "
              ++ show code
              ++ ": "
              ++ renderProcessDetail output
          )
      ExitSuccess -> parseAwsSesPulumiResourceUrns (processStdout output)

presentUrns :: [Text.Text] -> [Text.Text] -> [Text.Text]
presentUrns registered observed = filter (`elem` observed) registered

purgeAwsSesCaptureBucket
  :: FilePath
  -> [(String, String)]
  -> String
  -> IO (Either String ())
purgeAwsSesCaptureBucket workingDirectory environment bucket = do
  headResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = ["s3api", "head-bucket", "--bucket", bucket]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDirectory
        }
  case headResult of
    Failure detail -> pure (Left ("failed to start aws s3api head-bucket: " ++ detail))
    Success output ->
      case classifyAwsSesPresenceOutput (AwsSesCaptureBucketProbe bucket) output of
        ResidueStatus.PresenceAbsent -> pure (Right ())
        ResidueStatus.PresenceUnobservable failure ->
          pure (Left (renderObservationFailure failure))
        ResidueStatus.PresencePresent () -> do
          currentResult <-
            captureSubprocessResult
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments = ["s3", "rm", "s3://" ++ bucket, "--recursive"]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just workingDirectory
                }
          case currentResult of
            Failure detail -> pure (Left ("failed to start aws s3 rm: " ++ detail))
            Success currentOutput -> case processExitCode currentOutput of
              ExitFailure code ->
                pure
                  ( Left
                      ( "aws s3 rm exited with code "
                          ++ show code
                          ++ ": "
                          ++ renderProcessDetail currentOutput
                      )
                  )
              ExitSuccess -> purgeRemainingVersions workingDirectory environment bucket Nothing

providerUnreachable :: String -> ResidueStatus.ResidueStatus
providerUnreachable detail =
  ResidueStatus.ResidueUnreachable
    (ResidueStatus.ResidueQueryFailed detail)

-- | Sprint 7.14: aws-ses destroy authenticates the AWS provider with
-- admin credentials (`aws_admin_for_test_simulation.*`) and consults the
-- encrypted scratch backend. The operational @aws.*@ block is no longer
-- read on this path.
destroyAwsSesStackStatus
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Bool
  -> IO (Either String String)
destroyAwsSesStackStatus authentication repoRoot quietOutput = do
  currentSnapshot <-
    fetchAwsSesStackSnapshotFromBackendWithAuthentication authentication repoRoot
  let projectDir = awsSesPulumiProjectDir repoRoot
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err ->
      case currentSnapshot of
        Nothing ->
          pure
            (Right "no admin AWS credentials configured and no saved residue snapshot; nothing to destroy")
        Just _ -> pure (Left ("admin AWS credentials required to destroy the AWS SES stack: " ++ err))
    Right adminCreds -> do
      backendEnvironment <- pulumiSesProviderBaseEnv adminCreds
      backendResult <-
        withAwsSesEncryptedStackEnvironment
          authentication
          repoRoot
          projectDir
          adminCreds
          backendEnvironment
          ( \environment -> runDestroyAwsSesPulumiCycle repoRoot projectDir environment currentSnapshot quietOutput
          )
      pure $ case backendResult of
        Left err -> Left (renderEncryptedBackendError err)
        Right status -> Right status

runDestroyAwsSesPulumiCycle
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe AwsSesStackSnapshot
  -> Bool
  -> IO (Either String String)
runDestroyAwsSesPulumiCycle repoRoot projectDir baseEnvironment currentSnapshot quietOutput = do
  loginResult <- pulumiLoginEither projectDir baseEnvironment quietOutput
  case loginResult of
    Left err
      | currentSnapshot == Nothing
          && LiveResidue.isMissingStateBackendBucketMessage err ->
          pure (Right "already absent from the long-lived Pulumi backend")
      | otherwise -> pure (Left ("pulumi login failed: " ++ err))
    Right () -> do
      selectExit <- pulumiStackSelect projectDir baseEnvironment False
      case selectExit of
        PulumiStackSelected -> do
          configResult <- resolveAwsSesStackConfig repoRoot
          case configResult of
            Left err -> pure (Left err)
            Right stackConfig -> do
              syncExit <- syncAwsSesStackConfig projectDir baseEnvironment stackConfig
              case syncExit of
                ExitFailure _ -> pure (Left "pulumi config set failed")
                ExitSuccess -> do
                  destroyResult <- pulumiDestroyEither projectDir baseEnvironment quietOutput
                  case destroyResult of
                    Left err -> pure (Left ("pulumi destroy failed: " ++ err))
                    Right () -> completeDestroy repoRoot projectDir baseEnvironment quietOutput
        PulumiStackMissing ->
          case currentSnapshot of
            Nothing -> pure (Right "already absent from the long-lived Pulumi backend")
            Just _ -> finalizeDestroy
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))

-- | Sprint 4.79: the @pulumi stack rm@ result is __bound__.
--
-- It used to be discarded with @_ <-@ and followed by an unconditional
-- @Right \"destroyed\"@, so a failed stack removal was reported to the operator
-- as a completed destroy — on the terminal node of the @nuke@ decommission DAG.
-- The destroy itself had already succeeded at that point, which is why the
-- outcome is __reported__ rather than turned into a hard failure: the AWS
-- resources are gone, and what survives is a Pulumi stack entry naming them.
-- Calling that "destroyed" was the defect; calling it a failure would refuse a
-- teardown that did in fact remove every resource.
--
-- [lifecycle_reconciliation_doctrine.md § 3](../../../documents/engineering/lifecycle_reconciliation_doctrine.md)
-- — /Cleanup continues without lying/ — is exactly this shape.
completeDestroy
  :: FilePath -> FilePath -> [(String, String)] -> Bool -> IO (Either String String)
completeDestroy _repoRoot projectDir environment quietOutput = do
  removeResult <- pulumiStackRemoveEither projectDir environment False quietOutput
  pure (Right (destroySummaryFromStackRemove removeResult))

-- | The pure half of 'completeDestroy': what the operator is told, given
-- whether the stack entry was removed.
--
-- Pure and exported so the distinction is testable without a Pulumi backend —
-- the defect was a narration, and a narration nothing can observe is how it
-- survived.
destroySummaryFromStackRemove :: Either String () -> String
destroySummaryFromStackRemove removeResult = case removeResult of
  Right () -> destroyedSummary
  Left err ->
    destroyedSummary
      ++ "; the Pulumi stack entry was NOT removed and remains in the "
      ++ "long-lived backend ("
      ++ err
      ++ "). Every AWS resource was destroyed; re-run the destroy to clear the "
      ++ "stack entry."

finalizeDestroy :: IO (Either String String)
finalizeDestroy = pure (Right destroyedSummary)

destroyedSummary :: String
destroyedSummary = "destroyed"

pulumiLoginEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiLoginEither projectDir environment quietOutput
  | quietOutput = pulumiLoginQuiet projectDir environment
  | otherwise = exitToEither "pulumi login" <$> pulumiLogin projectDir environment

pulumiDestroyEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiDestroyEither projectDir environment quietOutput
  | quietOutput = pulumiDestroyQuiet projectDir environment
  | otherwise =
      exitToEither "pulumi destroy"
        <$> runPulumiCommand
          projectDir
          environment
          ["destroy", "--yes", "--stack", awsSesStackName]

pulumiStackRemoveEither
  :: FilePath -> [(String, String)] -> Bool -> Bool -> IO (Either String ())
pulumiStackRemoveEither projectDir environment force quietOutput
  | quietOutput = pulumiStackRemoveQuiet projectDir environment force
  | otherwise =
      exitToEither "pulumi stack rm"
        <$> runPulumiCommand
          projectDir
          environment
          ( ["stack", "rm", "--yes", "--remove-backups"]
              ++ ["--force" | force]
              ++ [awsSesStackName]
          )

exitToEither :: String -> ExitCode -> Either String ()
exitToEither _ ExitSuccess = Right ()
exitToEither label (ExitFailure code) = Left (label ++ " exited with code " ++ show code)

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | Operator compatibility entrypoint for the @aws-ses@ backend
-- migration. The first-touch import/delete logic now lives in the
-- encrypted backend wrapper; this command simply opens that wrapper
-- and selects the stack from the scratch backend so the wrapper can
-- persist an encrypted checkpoint and delete the legacy raw source
-- only after a successful supported action.
migrateAwsSesStackBackend :: FilePath -> IO ExitCode
migrateAwsSesStackBackend repoRoot = do
  requireInteractiveTty awsSesMigrateBackendGuard
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> migrateAwsSesStackBackendWithAuthentication authentication repoRoot)
  case authenticated of
    Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
    Right exitCode -> pure exitCode

migrateAwsSesStackBackendWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ExitCode
migrateAwsSesStackBackendWithAuthentication authentication repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> failWith err
    Right adminCreds -> do
      let projectDir = awsSesPulumiProjectDir repoRoot
      projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
      if not projectExists
        then failWith ("Pulumi AWS SES project missing: " ++ projectDir)
        else do
          baseEnvironment <- pulumiSesProviderBaseEnv adminCreds
          writeOutputLine "AWS_SES_BACKEND_MIGRATION"
          runResult <-
            withAwsSesEncryptedStackEnvironment
              authentication
              repoRoot
              projectDir
              adminCreds
              baseEnvironment
              (runEncryptedAwsSesBackendMigration projectDir)
          case runResult of
            Left err -> failWith (renderEncryptedBackendError err)
            Right status -> do
              writeOutputLine status
              pure ExitSuccess

runEncryptedAwsSesBackendMigration
  :: FilePath -> [(String, String)] -> IO (Either String String)
runEncryptedAwsSesBackendMigration projectDir environment = do
  loginResult <- pulumiLoginQuiet projectDir environment
  case loginResult of
    Left err -> pure (Left ("pulumi login failed: " ++ err))
    Right () -> do
      selectResult <- pulumiStackSelect projectDir environment False
      pure $ case selectResult of
        PulumiStackSelected -> Right "STATUS=encrypted-backend-ready"
        PulumiStackMissing -> Right "STATUS=absent"
        PulumiStackSelectFailed detail ->
          Left ("pulumi stack select failed: " ++ detail)
