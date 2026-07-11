{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsSesStack
  ( AwsSesStackSnapshot (..)
  , AwsSesResource (..)
  , AwsSesPresenceInventory (..)
  , AwsSesCheckpointSnapshot (..)
  , AwsSesPresenceProbe (..)
  , AwsSesTargetSelection
  , AwsSesTransactionStage (..)
  , awsSesStackName
  , awsSesDesiredPresentStages
  , runAwsSesTransactionStagesWith
  , awsSesPresenceInventoryComplete
  , awsSesTargetSelectionForSink
  , defaultAwsSesTargetSelection
  , keycloakSmtpVaultFields
  , mkAwsSesTargetSelection
  , classifyAwsSesPresenceOutput
  , observeAwsSesPresence
  , observeAwsSesCheckpoint
  , ensureAwsSesStackResources
  , ensureAwsSesStackResourcesForAuthorityAndTarget
  , ensureAwsSesStackResourcesForTarget
  , syncKeycloakSmtpChartSecrets
  , syncKeycloakSmtpChartSecretsForTarget
  , destroyAwsSesStack
  , awsSesStackResidueStatus
  , assertNoAwsSesStackResidue
  , migrateAwsSesStackBackend
  , renderAwsSesStackReport
  , parseAwsSesStackFromOutputs
  )
where

import Codec.Serialise (serialise)
import Control.Exception
  ( SomeException
  , mask
  , throwIO
  , try
  )
import Control.Monad (foldM, void)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (find, isInfixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.CLI.Interactive
  ( awsSesMigrateBackendGuard
  , requireInteractiveTty
  )
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack
  ( awsEksCanonicalClusterName
  , loadOperationalAwsCredentials
  , pulumiAwsProviderEnv
  , settingsAwsEnv
  )
import Prodbox.Infra.AwsSesLeaseRole
  ( awsSesLeaseRoleArn
  )
import Prodbox.Infra.AwsSesSmtpKey
  ( awsSesSmtpCommitCoordinate
  , createAwsSesSmtpAccessKey
  , deleteAwsSesSmtpAccessKey
  , observeAwsSesSmtpKeyInventory
  , smtpKeyMaterialDigest
  )
import Prodbox.Infra.LongLivedPulumiBackend
  ( loadAdminAwsCredentials
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrlEither
  )
import Prodbox.Infra.MinioBackend
  ( pulumiBackendLoginTimeoutSeconds
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( resolveLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , TargetClusterSecretSink
  , checkpointAuthorityClusterId
  , checkpointAuthorityGatewayEndpoint
  , mkModelBObjectCoordinate
  , mkTargetClusterSecretSink
  , targetSecretSinkGatewayEndpoint
  , targetSecretSinkIdentity
  )
import Prodbox.Lifecycle.CheckpointAuthorityStore
  ( ModelBCodec (..)
  , gatewayModelBCasAdapter
  )
import Prodbox.Lifecycle.DesiredPresence qualified as DesiredPresence
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , LeaseGrant
  , LeaseKey
  , LeasePolicy
  , LeaseRecoveryPredecessor
  , LeaseUsePermit
  , LeaseWork (..)
  , ProviderObservation (..)
  , addAuthorityDuration
  , defaultSesLeasePolicy
  , leaseAcquireCoordinate
  , leaseKeyAccount
  , leasePolicyGrantTtl
  , leaseRecoveryNotBefore
  , leaseUseDeadline
  )
import Prodbox.Lifecycle.LeaseInterpreter
  ( LeaseAcquisition (..)
  , LeaseInterpreter
  , acquireLeaseDetailedWith
  , fencedCommitPermitWith
  , releaseLeaseWith
  , runLeaseWorkWith
  )
import Prodbox.Lifecycle.LeaseRuntime
  ( beginProductionLeaseAcquire
  , discoverAwsSesLeaseKey
  , leaseScopedAwsCredentials
  , mintLeaseScopedAwsSession
  , mkProductionLeaseRuntime
  , observeGatewayAuthorityTime
  , productionLeaseInterpreter
  , waitForGatewayAuthorityTime
  )
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpCommittedProjection
  , committedSmtpCredentialGeneration
  , committedSmtpCredentialKeyId
  , committedSmtpCredentialMaterial
  , decodeSmtpCommittedProjection
  , encodeSmtpCommittedProjection
  , mkSmtpKeyInventoryBound
  , smtpAccessKeyIdText
  )
import Prodbox.Lifecycle.SmtpKeyRepairInterpreter
  ( SmtpKeyRepairInterpreter (..)
  , SmtpKeyRepairRequest (..)
  , runSmtpKeyRepairWith
  , smtpKeyRepairOutcomeCredential
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( RegisteredTargetSet
  , TargetIntentCoordinate
  , TargetIntentProjection
  , TargetValueDigest
  , decodeTargetIntentProjection
  , encodeTargetIntentProjection
  , mkRegisteredTargetSet
  , mkTargetIntentCoordinate
  , registeredTargetByIdentity
  , sha256TargetValueDigest
  )
import Prodbox.Lifecycle.TargetCommitInterpreter
  ( TargetCommitInterpreter (..)
  , TargetRecoveryInterpreter (..)
  , runPreparedTargetCommit
  , runSuccessorTargetRecoveryAfter
  )
import Prodbox.Lifecycle.TargetSecretStore
  ( gatewayTargetSecretAdapter
  )
import Prodbox.Pulumi.EncryptedBackend
  ( CheckpointObservability (..)
  , EncryptedBackendError
  , LegacyPulumiBackend (..)
  , PulumiStackRef (..)
  , classifyCheckpointBytes
  , renderEncryptedBackendError
  , withDecryptedStackEnvironment
  , withFencedDecryptedStackEnvironment
  , withMigratedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
import Prodbox.Ses.Readiness
  ( AwsSesProviderReadiness (..)
  , AwsSesReadiness (..)
  , AwsSesReadinessEnvironments (..)
  , AwsSesReadinessExpectation
  , AwsSesReadinessScope (..)
  , canonicalAwsSesPropagationPolicy
  , mkAwsSesReadinessExpectation
  , observeAwsSesReadiness
  , pollAwsSesReadiness
  , providerThenSemanticReadiness
  , renderAwsSesReadinessPollFailure
  , sesCaptureKeyPrefix
  , sesCaptureReadinessKey
  , sesInboundMxPriority
  , sesInboundMxTarget
  , sesReceiveRuleName
  , sesReceiveRuleSetName
  )
import Prodbox.Ses.SmtpPassword (derivedSesSmtpPassword)
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
  , sesSnapshotSmtpEndpoint :: String
  , sesSnapshotSmtpIamUserName :: String
  , sesSnapshotSmtpIamUserArn :: String
  , sesSnapshotSmtpIamAccessKeyId :: Maybe String
  }
  deriving (Eq, Show)

-- | Finite fixed-name resources used by checkpoint import/repair. This is an
-- authoritative AWS inventory, not a projection of Pulumi state.
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

-- | The one supported desired-present transaction order.  Keeping readiness
-- separate from Pulumi reconciliation prevents a successful provider return
-- from being mistaken for externally visible IAM/SES/S3 state, while keeping
-- SMTP repair and target materialization inside the final fenced work budget.
data AwsSesTransactionStage
  = AwsSesStageReconcile
  | AwsSesStageAwaitReady
  | AwsSesStageRepairAndMaterializeSmtp
  deriving (Bounded, Enum, Eq, Show)

awsSesDesiredPresentStages :: [AwsSesTransactionStage]
awsSesDesiredPresentStages =
  [ AwsSesStageReconcile
  , AwsSesStageAwaitReady
  , AwsSesStageRepairAndMaterializeSmtp
  ]

awsSesPresenceInventoryComplete :: AwsSesPresenceInventory -> Bool
awsSesPresenceInventoryComplete inventory =
  sort (awsSesPresentResources inventory)
    == sort
      [ AwsSesCaptureBucket
      , AwsSesCaptureReadinessObject
      , AwsSesSmtpIamUser
      , AwsSesReceiveRuleSet
      , AwsSesReceiveRule
      ]

-- | One selected target plus the complete finite set a successor must be able
-- to reason about.  The selected sink must be byte-for-byte the registered
-- sink for its identity; endpoint substitution is therefore rejected before
-- any target intent is prepared.
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

-- | Operator-default target selection.  The retained home gateway is the
-- selected sink.  The AWS identity is registered with an intentionally
-- unreachable placeholder endpoint so the projection identity set remains
-- stable across home/AWS runs; a capability-derived AWS run replaces that
-- endpoint with its live scoped port-forward.  If an outstanding AWS intent
-- exists, the placeholder fails closed instead of redirecting it to home.
defaultAwsSesTargetSelection
  :: LongLivedCheckpointAuthority -> Either String AwsSesTargetSelection
defaultAwsSesTargetSelection authority = do
  home <- awsSesHomeTargetSink authority
  awsSesTargetSelectionForSink authority home

-- | Construct the complete, stable SES target registry around one explicitly
-- selected sink.  The retained authority always defines the exact home sink.
-- A home selection must match that sink byte-for-byte; an AWS selection must
-- use the canonical EKS identity and SMTP secret coordinate, while its scoped
-- live gateway endpoint remains caller-supplied (for example a port-forward).
-- No other target identity or home endpoint substitution is accepted.
awsSesTargetSelectionForSink
  :: LongLivedCheckpointAuthority
  -> TargetClusterSecretSink
  -> Either String AwsSesTargetSelection
awsSesTargetSelectionForSink authority selected = do
  home <- awsSesHomeTargetSink authority
  awsPlaceholder <- awsSesAwsPlaceholderTargetSink
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
          registered <- first show (mkRegisteredTargetSet 2 [home, awsPlaceholder])
          mkAwsSesTargetSelection registered home
        else
          if selectedIdentity == awsIdentity
            then do
              canonicalAws <-
                first show $
                  mkTargetClusterSecretSink
                    awsIdentity
                    (targetSecretSinkGatewayEndpoint selected)
                    "secret"
                    "keycloak/smtp"
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
  first show $
    mkTargetClusterSecretSink
      (checkpointAuthorityClusterId authority)
      (checkpointAuthorityGatewayEndpoint authority)
      "secret"
      "keycloak/smtp"

awsSesAwsPlaceholderTargetSink :: Either String TargetClusterSecretSink
awsSesAwsPlaceholderTargetSink =
  first show $
    mkTargetClusterSecretSink
      (Text.pack awsEksCanonicalClusterName)
      "http://127.0.0.1:1"
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

awsSesPresenceProbeResource :: AwsSesPresenceProbe -> AwsSesResource
awsSesPresenceProbeResource probe = case probe of
  AwsSesCaptureBucketProbe _ -> AwsSesCaptureBucket
  AwsSesCaptureReadinessObjectProbe _ -> AwsSesCaptureReadinessObject
  AwsSesSmtpIamUserProbe -> AwsSesSmtpIamUser
  AwsSesReceiveRuleSetProbe -> AwsSesReceiveRuleSet
  AwsSesReceiveRuleProbe -> AwsSesReceiveRule

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

observeAwsSesPresenceProbe
  :: FilePath
  -> [(String, String)]
  -> AwsSesPresenceProbe
  -> IO (ResidueStatus.PresenceObservation ())
observeAwsSesPresenceProbe workingDir environment probe = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = awsSesPresenceProbeArguments probe
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  pure $ case result of
    Failure err ->
      ResidueStatus.PresenceUnobservable
        ResidueStatus.ObservationFailure
          { ResidueStatus.observationFailureOperation = awsSesPresenceProbeOperation probe
          , ResidueStatus.observationFailureDetail = "failed to start aws: " ++ err
          }
    Success output -> classifyAwsSesPresenceOutput probe output

observeAwsSesPresenceWith
  :: FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (ResidueStatus.PresenceObservation AwsSesPresenceInventory)
observeAwsSesPresenceWith workingDir environment stackConfig = do
  let probes =
        [ AwsSesCaptureBucketProbe (sesStackCaptureBucket stackConfig)
        , AwsSesCaptureReadinessObjectProbe (sesStackCaptureBucket stackConfig)
        , AwsSesSmtpIamUserProbe
        , AwsSesReceiveRuleSetProbe
        , AwsSesReceiveRuleProbe
        ]
  observations <-
    mapM
      (\probe -> (probe,) <$> observeAwsSesPresenceProbe workingDir environment probe)
      probes
  pure $
    case find (isUnobservable . snd) observations of
      Just (_, ResidueStatus.PresenceUnobservable failure) ->
        ResidueStatus.PresenceUnobservable failure
      _ ->
        let presentResources =
              [ awsSesPresenceProbeResource probe
              | (probe, ResidueStatus.PresencePresent ()) <- observations
              ]
         in case presentResources of
              [] -> ResidueStatus.PresenceAbsent
              resources ->
                ResidueStatus.PresencePresent
                  AwsSesPresenceInventory
                    { awsSesPresentResources = resources
                    }
 where
  isUnobservable observation = case observation of
    ResidueStatus.PresenceUnobservable _ -> True
    _ -> False

-- | Production authoritative AWS inventory observation. Configuration or
-- credential acquisition failures are unobservable facts and therefore close
-- the desired-present gate.
observeAwsSesPresence
  :: FilePath -> IO (ResidueStatus.PresenceObservation AwsSesPresenceInventory)
observeAwsSesPresence repoRoot = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  operationalResult <- loadOperationalAwsCredentials repoRoot
  configResult <- case operationalResult of
    Left err -> pure (Left err)
    Right credentials -> resolveAwsSesStackConfigForCredentials repoRoot credentials
  case (configResult, operationalResult) of
    (Left err, _) -> pure (presenceObservationFailure "resolve aws-ses configuration" err)
    (_, Left err) -> pure (presenceObservationFailure "load operational AWS credential" err)
    (Right stackConfig, Right operationalCredentials) -> do
      providerEnvironment <- pulumiSesProviderBaseEnv operationalCredentials
      observeAwsSesPresenceWith
        projectDir
        (awsCliCredsFromProviderEnv providerEnvironment)
        stackConfig

-- | Production Model-B checkpoint observation. Empty objects are corrupt for
-- desired-present repair (they were positively observed but are not usable),
-- while only a missing object becomes 'CheckpointMissing'.
observeAwsSesCheckpoint
  :: FilePath -> IO (ResidueStatus.CheckpointObservation AwsSesCheckpointSnapshot)
observeAwsSesCheckpoint repoRoot = do
  authorityResult <- resolveLongLivedCheckpointAuthority repoRoot
  case authorityResult of
    Left err -> pure (checkpointObservationFailure "resolve retained checkpoint authority" err)
    Right authority ->
      case awsSesCheckpointCoordinate authority of
        Left err -> pure (checkpointObservationFailure "resolve aws-ses checkpoint coordinate" err)
        Right coordinate ->
          observeAwsSesCheckpointWith
            (gatewayModelBCasAdapter authority byteStringModelBCodec)
            coordinate

observeAwsSesCheckpointWith
  :: ModelBCasAdapter IO ByteString
  -> ModelBObjectCoordinate
  -> IO (ResidueStatus.CheckpointObservation AwsSesCheckpointSnapshot)
observeAwsSesCheckpointWith adapter coordinate = do
  observed <- modelBObserve adapter coordinate
  pure $ case observed of
    ModelBMissing -> ResidueStatus.CheckpointMissing
    ModelBCorrupt detail -> corruptCheckpoint (Text.unpack detail)
    ModelBUnobservable detail ->
      checkpointObservationFailure "observe aws-ses Model-B checkpoint" (Text.unpack detail)
    ModelBObserved _ bytes ->
      case classifyCheckpointBytes (Just bytes) of
        CheckpointAbsent -> ResidueStatus.CheckpointMissing
        CheckpointEmpty -> corruptCheckpoint "checkpoint object is empty"
        CheckpointCorrupt detail -> corruptCheckpoint detail
        CheckpointPresent ->
          ResidueStatus.CheckpointValid
            AwsSesCheckpointSnapshot
              { awsSesCheckpointStackName = awsSesStackName
              }

awsSesCheckpointCoordinate
  :: LongLivedCheckpointAuthority -> Either String ModelBObjectCoordinate
awsSesCheckpointCoordinate authority =
  case mkModelBObjectCoordinate authority "pulumi-stack/aws-ses" of
    Left err -> Left (show err)
    Right coordinate -> Right coordinate

byteStringModelBCodec :: ModelBCodec ByteString
byteStringModelBCodec =
  ModelBCodec
    { encodeModelBValue = Right
    , decodeModelBValue = Right
    }

smtpCommittedModelBCodec :: ModelBCodec SmtpCommittedProjection
smtpCommittedModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . encodeSmtpCommittedProjection
    , decodeModelBValue = first show . decodeSmtpCommittedProjection
    }

targetIntentModelBCodec
  :: RegisteredTargetSet -> ModelBCodec TargetIntentProjection
targetIntentModelBCodec registered =
  ModelBCodec
    { encodeModelBValue = Right . encodeTargetIntentProjection
    , decodeModelBValue =
        first show . decodeTargetIntentProjection registered
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

presenceObservationFailure
  :: String -> String -> ResidueStatus.PresenceObservation inventory
presenceObservationFailure operation detail =
  ResidueStatus.PresenceUnobservable
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
fetchAwsSesStackSnapshotFromBackend
  :: FilePath -> IO (Maybe AwsSesStackSnapshot)
fetchAwsSesStackSnapshotFromBackend repoRoot = do
  outputsResult <- LiveResidue.fetchAwsSesStackOutputs repoRoot
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
  smtpEndpoint <- requireMapString outputs "smtp_endpoint"
  smtpIamUserName <- requireMapString outputs "smtp_iam_user_name"
  smtpIamUserArn <- requireMapString outputs "smtp_iam_user_arn"
  let smtpIamAccessKeyId = optionalMapString outputs "smtp_iam_access_key_id"
      snapshot =
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
          , sesSnapshotSmtpEndpoint = smtpEndpoint
          , sesSnapshotSmtpIamUserName = smtpIamUserName
          , sesSnapshotSmtpIamUserArn = smtpIamUserArn
          , sesSnapshotSmtpIamAccessKeyId = smtpIamAccessKeyId
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

optionalMapString :: Map Text.Text Text.Text -> String -> Maybe String
optionalMapString outputs key = do
  raw <- Map.lookup (Text.pack key) outputs
  let value = Text.strip raw
  if Text.null value then Nothing else Just (Text.unpack value)

snapshotFromOutputs :: Value -> Either String AwsSesStackSnapshot
snapshotFromOutputs (Object obj) = do
  backendBucket <- requireString obj "backend_bucket"
  awsRegion <- requireString obj "aws_region"
  sendingDomain <- requireString obj "sending_domain"
  receiveSubdomain <- requireString obj "receive_subdomain"
  receiveSubdomainMxFqdn <- requireString obj "receive_subdomain_mx_fqdn"
  receiveSubdomainMxPriority <-
    requireString obj "receive_subdomain_mx_priority"
      >>= requireIntOutput "receive_subdomain_mx_priority"
  receiveSubdomainMxTarget <- requireString obj "receive_subdomain_mx_target"
  receiveRuleSetName <- requireString obj "receive_rule_set_name"
  receiveRuleName <- requireString obj "receive_rule_name"
  captureBucketName <- requireString obj "capture_bucket_name"
  captureBucketArn <- requireString obj "capture_bucket_arn"
  captureBucketKeyPrefix <- requireString obj "capture_bucket_key_prefix"
  captureReadinessKey <- requireString obj "capture_readiness_key"
  smtpEndpoint <- requireString obj "smtp_endpoint"
  smtpIamUserName <- requireString obj "smtp_iam_user_name"
  smtpIamUserArn <- requireString obj "smtp_iam_user_arn"
  let smtpIamAccessKeyId = optionalString obj "smtp_iam_access_key_id"
      snapshot =
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
          , sesSnapshotSmtpEndpoint = smtpEndpoint
          , sesSnapshotSmtpIamUserName = smtpIamUserName
          , sesSnapshotSmtpIamUserArn = smtpIamUserArn
          , sesSnapshotSmtpIamAccessKeyId = smtpIamAccessKeyId
          }
  validateAwsSesStackSnapshot snapshot
snapshotFromOutputs _ = Left "aws-ses pulumi output must be a JSON object"

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

requireString :: KeyMap.KeyMap Value -> String -> Either String String
requireString obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (String text) ->
      let str = Text.unpack text
       in if null str then Left ("missing string output " ++ key) else Right str
    _ -> Left ("missing string output " ++ key)

optionalString :: KeyMap.KeyMap Value -> String -> Maybe String
optionalString obj key = case KeyMap.lookup (Key.fromString key) obj of
  Just (String raw)
    | not (Text.null (Text.strip raw)) -> Just (Text.unpack (Text.strip raw))
  _ -> Nothing

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
      , "SMTP_ENDPOINT=" ++ sesSnapshotSmtpEndpoint snapshot
      , "SMTP_IAM_USER_NAME=" ++ sesSnapshotSmtpIamUserName snapshot
      , "SMTP_IAM_USER_ARN=" ++ sesSnapshotSmtpIamUserArn snapshot
      ]
        ++ maybe
          []
          (\keyId -> ["SMTP_IAM_ACCESS_KEY_ID=" ++ keyId])
          (sesSnapshotSmtpIamAccessKeyId snapshot)
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
    [ ("parentZoneId", sesStackParentZoneId stackConfig)
    , ("senderDomain", sesStackSenderDomain stackConfig)
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
  :: FilePath
  -> FilePath
  -> Credentials
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withAwsSesEncryptedStackEnvironment repoRoot projectDir adminCreds environment action = do
  legacyBackend <- awsSesLegacyPulumiBackend repoRoot projectDir adminCreds
  case legacyBackend of
    Nothing ->
      withDecryptedStackEnvironment repoRoot awsSesPulumiStackRef environment action
    Just legacy ->
      withMigratedDecryptedStackEnvironment repoRoot awsSesPulumiStackRef legacy environment action

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

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
  runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsSesStackName]

pulumiDestroyQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiDestroyQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["destroy", "--yes", "--stack", awsSesStackName]

pulumiStackRemoveQuiet :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiStackRemoveQuiet projectDir environment force =
  runPulumiCommandQuiet
    projectDir
    environment
    (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsSesStackName])

pulumiStackOutputs :: FilePath -> [(String, String)] -> IO (Either String Value)
pulumiStackOutputs projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["stack", "output", "--json", "--stack", awsSesStackName]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  case result of
    Failure err -> pure (Left ("failed to run pulumi stack output: " ++ err))
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          pure (Left ("pulumi stack output failed: " ++ trim (processStderr output)))
        ExitSuccess ->
          case eitherDecode (BL8.pack (processStdout output)) of
            Left err -> pure (Left ("failed to parse pulumi output JSON: " ++ err))
            Right value -> pure (Right value)

data AwsSesLeaseTransaction = AwsSesLeaseTransaction
  { awsSesTransactionRepoRoot :: !FilePath
  , awsSesTransactionAuthority :: !LongLivedCheckpointAuthority
  , awsSesTransactionPolicy :: !LeasePolicy
  , awsSesTransactionLeaseCoordinate :: !ModelBObjectCoordinate
  , awsSesTransactionLeaseKey :: !LeaseKey
  , awsSesTransactionTargetCoordinate :: !TargetIntentCoordinate
  , awsSesTransactionInterpreter :: !(LeaseInterpreter IO (Maybe AwsSesPresenceInventory))
  , awsSesTransactionStackConfig :: !AwsSesStackConfig
  , awsSesTransactionOperationalCredentials :: !Credentials
  , awsSesTransactionProjectDir :: !FilePath
  }

leaseRuntimePollMicros :: Int
leaseRuntimePollMicros = 1000000

-- | Acquire the retained account-scoped lease, recover any predecessor's
-- cross-authority intent, run the caller, and owner/fence-release on every
-- ordinary, exceptional, or asynchronous exit.
withAwsSesLeaseTransaction
  :: FilePath
  -> AwsSesTargetSelection
  -> (AwsSesLeaseTransaction -> LeaseGrant -> IO (Either String value))
  -> IO (Either String value)
withAwsSesLeaseTransaction repoRoot selection action = do
  operationalResult <- loadOperationalAwsCredentials repoRoot
  authorityResult <- resolveLongLivedCheckpointAuthority repoRoot
  case (operationalResult, authorityResult) of
    (Left err, _) -> pure (Left ("load operational AWS credentials: " ++ err))
    (_, Left err) -> pure (Left err)
    (Right operationalCredentials, Right authority) ->
      runAwsSesLeaseTransaction
        repoRoot
        authority
        operationalCredentials
        selection
        action

-- | The explicit-authority transaction boundary used by capability-derived
-- retained SES preparation.  It deliberately does not resolve or infer the
-- authority from repository state; all lease, checkpoint, recovery, and
-- target-intent operations use the supplied retained authority.
withAwsSesLeaseTransactionForAuthority
  :: FilePath
  -> LongLivedCheckpointAuthority
  -> AwsSesTargetSelection
  -> (AwsSesLeaseTransaction -> LeaseGrant -> IO (Either String value))
  -> IO (Either String value)
withAwsSesLeaseTransactionForAuthority repoRoot authority selection action = do
  operationalResult <- loadOperationalAwsCredentials repoRoot
  case operationalResult of
    Left err -> pure (Left ("load operational AWS credentials: " ++ err))
    Right operationalCredentials ->
      runAwsSesLeaseTransaction
        repoRoot
        authority
        operationalCredentials
        selection
        action

runAwsSesLeaseTransaction
  :: FilePath
  -> LongLivedCheckpointAuthority
  -> Credentials
  -> AwsSesTargetSelection
  -> (AwsSesLeaseTransaction -> LeaseGrant -> IO (Either String value))
  -> IO (Either String value)
runAwsSesLeaseTransaction repoRoot authority operationalCredentials selection action = do
  let projectDir = awsSesPulumiProjectDir repoRoot
      policy = defaultSesLeasePolicy
  configResult <-
    resolveAwsSesStackConfigForCredentials repoRoot operationalCredentials
  keyResult <- discoverAwsSesLeaseKey operationalCredentials
  case (configResult, keyResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left ("discover aws-ses lease identity: " ++ show err))
    (Right stackConfig, Right leaseKey) ->
      case mkTargetIntentCoordinate authority leaseKey of
        Left err -> pure (Left ("resolve target-intent coordinate: " ++ show err))
        Right targetCoordinate -> do
          providerEnvironment <- pulumiSesProviderBaseEnv operationalCredentials
          runtimeResult <-
            pure $
              mkProductionLeaseRuntime
                authority
                policy
                (fromIntegral leaseRuntimePollMicros)
                ( observeAwsSesProviderQuiescence
                    projectDir
                    (awsCliCredsFromProviderEnv providerEnvironment)
                    stackConfig
                )
          case runtimeResult of
            Left err -> pure (Left ("configure aws-ses lease runtime: " ++ show err))
            Right runtime -> do
              requestResult <- beginProductionLeaseAcquire authority policy leaseKey
              case requestResult of
                Left err -> pure (Left ("begin aws-ses lease acquisition: " ++ show err))
                Right request -> do
                  let interpreter = productionLeaseInterpreter runtime
                      leaseCoordinate = leaseAcquireCoordinate request
                  acquisitionResult <- acquireLeaseDetailedWith interpreter policy request
                  case acquisitionResult of
                    Left err -> pure (Left ("acquire aws-ses lease: " ++ show err))
                    Right acquisition ->
                      runAcquiredLease
                        interpreter
                        policy
                        leaseCoordinate
                        (leaseAcquisitionGrant acquisition)
                        ( do
                            recovery <-
                              recoverAwsSesTargetIntents
                                authority
                                interpreter
                                policy
                                leaseCoordinate
                                (leaseAcquisitionGrant acquisition)
                                (leaseAcquisitionRecoveryPredecessor acquisition)
                                selection
                                targetCoordinate
                            case recovery of
                              Left err -> pure (Left err)
                              Right () ->
                                action
                                  AwsSesLeaseTransaction
                                    { awsSesTransactionRepoRoot = repoRoot
                                    , awsSesTransactionAuthority = authority
                                    , awsSesTransactionPolicy = policy
                                    , awsSesTransactionLeaseCoordinate = leaseCoordinate
                                    , awsSesTransactionLeaseKey = leaseKey
                                    , awsSesTransactionTargetCoordinate = targetCoordinate
                                    , awsSesTransactionInterpreter = interpreter
                                    , awsSesTransactionStackConfig = stackConfig
                                    , awsSesTransactionOperationalCredentials = operationalCredentials
                                    , awsSesTransactionProjectDir = projectDir
                                    }
                                  (leaseAcquisitionGrant acquisition)
                        )

runAcquiredLease
  :: LeaseInterpreter IO inventory
  -> LeasePolicy
  -> ModelBObjectCoordinate
  -> LeaseGrant
  -> IO (Either String value)
  -> IO (Either String value)
runAcquiredLease interpreter policy coordinate grant action =
  mask $ \restore -> do
    actionResult <- tryAny (restore action)
    releaseResult <- releaseLeaseWith interpreter policy coordinate grant
    case actionResult of
      Left exception -> do
        case releaseResult of
          Left releaseError ->
            writeDiagnosticLine
              ( "aws-ses lease release also failed during exception cleanup: "
                  ++ show releaseError
              )
          Right () -> pure ()
        throwIO exception
      Right (Left actionError) ->
        pure $ case releaseResult of
          Left releaseError ->
            Left
              ( actionError
                  ++ "; aws-ses lease release also failed: "
                  ++ show releaseError
              )
          Right () -> Left actionError
      Right (Right value) ->
        pure $ case releaseResult of
          Left releaseError ->
            Left ("aws-ses lease release failed: " ++ show releaseError)
          Right () -> Right value

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

observeAwsSesProviderQuiescence
  :: FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (ProviderObservation (Maybe AwsSesPresenceInventory))
observeAwsSesProviderQuiescence projectDir environment stackConfig = do
  observed <- observeAwsSesPresenceWith projectDir environment stackConfig
  pure $ case observed of
    ResidueStatus.PresenceAbsent -> ProviderQuiescent Nothing
    ResidueStatus.PresencePresent inventory -> ProviderQuiescent (Just inventory)
    ResidueStatus.PresenceUnobservable failure ->
      ProviderUnobservable (Text.pack (show failure))

recoverAwsSesTargetIntents
  :: LongLivedCheckpointAuthority
  -> LeaseInterpreter IO inventory
  -> LeasePolicy
  -> ModelBObjectCoordinate
  -> LeaseGrant
  -> Maybe LeaseRecoveryPredecessor
  -> AwsSesTargetSelection
  -> TargetIntentCoordinate
  -> IO (Either String ())
recoverAwsSesTargetIntents _ _ _ _ _ Nothing _ _ = pure (Right ())
recoverAwsSesTargetIntents authority leaseInterpreter policy leaseCoordinate currentGrant (Just predecessor) selection coordinate = do
  let base =
        targetCommitInterpreterFor
          authority
          leaseInterpreter
          leaseCoordinate
          currentGrant
          selection
      recovery =
        TargetRecoveryInterpreter
          { targetRecoveryBaseInterpreter = base
          , targetRecoveryWaitUntil =
              waitForGatewayAuthorityTime authority leaseRuntimePollMicros
          , targetRecoveryWaitFor = waitForAuthorityDuration authority
          }
  result <-
    runSuccessorTargetRecoveryAfter
      recovery
      (awsSesRegisteredTargets selection)
      coordinate
      policy
      (leaseRecoveryNotBefore predecessor)
  pure (first (("recover predecessor target intents: " ++) . show) (void result))

waitForAuthorityDuration
  :: LongLivedCheckpointAuthority
  -> AuthorityDuration
  -> IO (Either Text.Text ())
waitForAuthorityDuration authority duration = do
  nowResult <- observeGatewayAuthorityTime authority
  case nowResult of
    Left err -> pure (Left err)
    Right now ->
      waitForGatewayAuthorityTime
        authority
        leaseRuntimePollMicros
        (addAuthorityDuration now duration)

targetCommitInterpreterFor
  :: LongLivedCheckpointAuthority
  -> LeaseInterpreter IO inventory
  -> ModelBObjectCoordinate
  -> LeaseGrant
  -> AwsSesTargetSelection
  -> TargetCommitInterpreter IO (Map Text.Text Text.Text)
targetCommitInterpreterFor authority leaseInterpreter leaseCoordinate grant selection =
  TargetCommitInterpreter
    { targetCommitGlobalAdapter =
        gatewayModelBCasAdapter
          authority
          (targetIntentModelBCodec (awsSesRegisteredTargets selection))
    , targetCommitSinkAdapter = gatewayTargetSecretAdapter
    , targetCommitCurrentPermit =
        first (Text.pack . show)
          <$> fencedCommitPermitWith leaseInterpreter leaseCoordinate grant
    , targetCommitCurrentAuthorityTime = observeGatewayAuthorityTime authority
    , targetCommitDigestPayload = smtpTargetPayloadDigest
    }

smtpTargetPayloadDigest :: Map Text.Text Text.Text -> TargetValueDigest
smtpTargetPayloadDigest =
  sha256TargetValueDigest
    . BL.toStrict
    . serialise
    . Map.toAscList

-- | Re-materialize already committed SMTP material into the selected target.
-- Unlike the retired Pulumi-output path, this never reads a secret output or
-- writes Vault with a host root token.
syncKeycloakSmtpChartSecrets :: FilePath -> IO (Either String ())
syncKeycloakSmtpChartSecrets repoRoot = do
  authorityResult <- resolveLongLivedCheckpointAuthority repoRoot
  case authorityResult >>= defaultAwsSesTargetSelection of
    Left err -> pure (Left err)
    Right selection -> syncKeycloakSmtpChartSecretsForTarget repoRoot selection

syncKeycloakSmtpChartSecretsForTarget
  :: FilePath -> AwsSesTargetSelection -> IO (Either String ())
syncKeycloakSmtpChartSecretsForTarget repoRoot selection =
  withAwsSesLeaseTransaction repoRoot selection $ \transaction grant ->
    runLeaseWorkAsString
      (awsSesTransactionInterpreter transaction)
      (awsSesTransactionPolicy transaction)
      (awsSesTransactionLeaseCoordinate transaction)
      LeaseSmtpCommitWork
      grant
      ( \permit -> do
          committed <- observeCommittedSmtpProjection transaction
          case committed of
            Left err -> pure (Left (Text.pack err))
            Right projection ->
              first Text.pack
                <$> materializeCommittedSmtp
                  transaction
                  selection
                  grant
                  permit
                  projection
      )

observeCommittedSmtpProjection
  :: AwsSesLeaseTransaction -> IO (Either String SmtpCommittedProjection)
observeCommittedSmtpProjection transaction = do
  leaseKeyResult <-
    discoverAwsSesLeaseKey (awsSesTransactionOperationalCredentials transaction)
  case leaseKeyResult of
    Left err -> pure (Left (show err))
    Right leaseKey ->
      case awsSesSmtpCommitCoordinate (awsSesTransactionAuthority transaction) leaseKey of
        Left err -> pure (Left (show err))
        Right coordinate -> do
          observed <-
            modelBObserve
              ( gatewayModelBCasAdapter
                  (awsSesTransactionAuthority transaction)
                  smtpCommittedModelBCodec
              )
              coordinate
          pure $ case observed of
            ModelBObserved _ committed -> Right committed
            ModelBMissing ->
              Left "no fenced SMTP credential is committed; reconcile aws-ses first"
            ModelBCorrupt detail -> Left ("SMTP committed projection is corrupt: " ++ Text.unpack detail)
            ModelBUnobservable detail -> Left ("SMTP committed projection is unobservable: " ++ Text.unpack detail)

runLeaseWorkAsString
  :: LeaseInterpreter IO inventory
  -> LeasePolicy
  -> ModelBObjectCoordinate
  -> LeaseWork
  -> LeaseGrant
  -> (LeaseUsePermit -> IO (Either Text.Text value))
  -> IO (Either String value)
runLeaseWorkAsString interpreter policy coordinate work grant action =
  first show
    <$> runLeaseWorkWith interpreter policy coordinate work grant action

materializeCommittedSmtp
  :: AwsSesLeaseTransaction
  -> AwsSesTargetSelection
  -> LeaseGrant
  -> LeaseUsePermit
  -> SmtpCommittedProjection
  -> IO (Either String ())
materializeCommittedSmtp transaction selection grant permit committed =
  case smtpVaultFieldsFromCommitted (awsSesTransactionStackConfig transaction) committed of
    Left err -> pure (Left err)
    Right fields -> do
      let digest = smtpTargetPayloadDigest fields
          targetInterpreter =
            targetCommitInterpreterFor
              (awsSesTransactionAuthority transaction)
              (awsSesTransactionInterpreter transaction)
              (awsSesTransactionLeaseCoordinate transaction)
              grant
              selection
      result <-
        runPreparedTargetCommit
          targetInterpreter
          (awsSesRegisteredTargets selection)
          (awsSesTransactionTargetCoordinate transaction)
          (awsSesSelectedTarget selection)
          (committedSmtpCredentialGeneration committed)
          digest
          (leaseUseDeadline permit)
          fields
      pure (first (("materialize fenced SMTP target: " ++) . show) (void result))

smtpVaultFieldsFromCommitted
  :: AwsSesStackConfig
  -> SmtpCommittedProjection
  -> Either String (Map Text.Text Text.Text)
smtpVaultFieldsFromCommitted stackConfig committed = do
  material <-
    maybe
      (Left "committed SMTP credential has no recoverable secret material")
      Right
      (committedSmtpCredentialMaterial committed)
  secretText <-
    first
      (const "committed SMTP credential secret material is not valid UTF-8")
      (TextEncoding.decodeUtf8' material)
  pure
    ( keycloakSmtpVaultFields
        (sesStackAwsRegion stackConfig)
        (sesStackSenderDomain stackConfig)
        ("email-smtp." ++ sesStackAwsRegion stackConfig ++ ".amazonaws.com")
        (Text.unpack (smtpAccessKeyIdText (committedSmtpCredentialKeyId committed)))
        (Text.unpack secretText)
    )

keycloakSmtpVaultFields
  :: String -> String -> String -> String -> String -> Map Text.Text Text.Text
keycloakSmtpVaultFields awsRegion senderDomain smtpEndpoint smtpAccessKeyId smtpSecret =
  let region = Text.pack awsRegion
      fromAddress = Text.pack ("noreply@" ++ senderDomain)
   in Map.fromList
        [ ("host", Text.pack smtpEndpoint)
        , ("port", "587")
        , ("from", fromAddress)
        , ("from_display_name", "prodbox")
        , ("reply_to", fromAddress)
        , ("username", Text.pack smtpAccessKeyId)
        , ("password", derivedSesSmtpPassword region (Text.pack smtpSecret))
        ]

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
  authorityResult <- resolveLongLivedCheckpointAuthority repoRoot
  case authorityResult >>= defaultAwsSesTargetSelection of
    Left err -> failWith err
    Right selection -> ensureAwsSesStackResourcesForTarget repoRoot selection

ensureAwsSesStackResourcesForTarget
  :: FilePath -> AwsSesTargetSelection -> IO ExitCode
ensureAwsSesStackResourcesForTarget repoRoot selection = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then failWith ("Pulumi AWS SES project missing: " ++ projectDir)
    else do
      result <-
        withAwsSesLeaseTransaction repoRoot selection $ \transaction grant ->
          runAwsSesTransactionStagesWith
            (runAwsSesTransactionStage selection transaction grant)
      case result of
        Left err -> failWith err
        Right () -> pure ExitSuccess

-- | Capability-derived retained SES preparation with both authorities made
-- explicit.  The selected registry is revalidated against the supplied
-- retained authority before any credentials are loaded or lease is acquired,
-- and the transaction never re-resolves that authority from ambient state.
ensureAwsSesStackResourcesForAuthorityAndTarget
  :: FilePath
  -> LongLivedCheckpointAuthority
  -> AwsSesTargetSelection
  -> IO ExitCode
ensureAwsSesStackResourcesForAuthorityAndTarget repoRoot authority selection =
  case awsSesTargetSelectionForSink authority (awsSesSelectedTarget selection) of
    Left err -> failWith err
    Right canonicalSelection
      | canonicalSelection /= selection ->
          failWith
            "selected SES target registry does not match the supplied retained authority"
      | otherwise -> do
          let projectDir = awsSesPulumiProjectDir repoRoot
          projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
          if not projectExists
            then failWith ("Pulumi AWS SES project missing: " ++ projectDir)
            else do
              result <-
                withAwsSesLeaseTransactionForAuthority
                  repoRoot
                  authority
                  selection
                  ( \transaction grant ->
                      runAwsSesTransactionStagesWith
                        (runAwsSesTransactionStage selection transaction grant)
                  )
              case result of
                Left err -> failWith err
                Right () -> pure ExitSuccess

runAwsSesTransactionStage
  :: AwsSesTargetSelection
  -> AwsSesLeaseTransaction
  -> LeaseGrant
  -> AwsSesTransactionStage
  -> IO (Either String ())
runAwsSesTransactionStage selection transaction grant stage =
  case stage of
    AwsSesStageReconcile -> runAwsSesReconcileStage transaction grant
    AwsSesStageAwaitReady -> runAwsSesReadinessStage transaction grant
    AwsSesStageRepairAndMaterializeSmtp ->
      runAwsSesSmtpStage selection transaction grant

-- | Interpret the exact production stage list with fail-fast sequencing.
-- This is the injected production seam used by tests to prove an await-stage
-- timeout, hard semantic failure, or unobservable result cannot reach SMTP
-- repair/materialization.  There is deliberately no destroy stage: ordinary
-- failure unwinds through the enclosing lease release while retaining the
-- long-lived stack.
runAwsSesTransactionStagesWith
  :: (Monad m)
  => (AwsSesTransactionStage -> m (Either errorValue ()))
  -> m (Either errorValue ())
runAwsSesTransactionStagesWith runStage = go awsSesDesiredPresentStages
 where
  go [] = pure (Right ())
  go (stage : remaining) = do
    result <- runStage stage
    case result of
      Left err -> pure (Left err)
      Right () -> go remaining

runAwsSesReconcileStage
  :: AwsSesLeaseTransaction -> LeaseGrant -> IO (Either String ())
runAwsSesReconcileStage transaction grant =
  runLeaseWorkAsString
    (awsSesTransactionInterpreter transaction)
    (awsSesTransactionPolicy transaction)
    (awsSesTransactionLeaseCoordinate transaction)
    LeaseReconcileWork
    grant
    ( \permit -> do
        sessionResult <- mintAwsSesWorkSession transaction permit
        case sessionResult of
          Left err -> pure (Left err)
          Right sessionCredentials -> do
            baseEnvironment <- pulumiSesProviderBaseEnv sessionCredentials
            result <-
              reconcileAwsSesDesiredPresence
                transaction
                grant
                sessionCredentials
                baseEnvironment
            pure (first Text.pack result)
    )

reconcileAwsSesDesiredPresence
  :: AwsSesLeaseTransaction
  -> LeaseGrant
  -> Credentials
  -> [(String, String)]
  -> IO (Either String ())
reconcileAwsSesDesiredPresence transaction grant sessionCredentials baseEnvironment =
  case awsSesCheckpointCoordinate (awsSesTransactionAuthority transaction) of
    Left err -> pure (Left err)
    Right checkpointCoordinate -> do
      legacy <-
        awsSesLegacyPulumiBackend
          (awsSesTransactionRepoRoot transaction)
          (awsSesTransactionProjectDir transaction)
          sessionCredentials
      let authority = awsSesTransactionAuthority transaction
          checkpointAdapter =
            gatewayModelBCasAdapter authority byteStringModelBCodec
          leaseInterpreter = awsSesTransactionInterpreter transaction
          leaseCoordinate = awsSesTransactionLeaseCoordinate transaction
          projectDir = awsSesTransactionProjectDir transaction
          stackConfig = awsSesTransactionStackConfig transaction
          awsEnvironment = awsCliCredsFromProviderEnv baseEnvironment
          authorizeCheckpoint =
            first show
              <$> fencedCommitPermitWith leaseInterpreter leaseCoordinate grant
      result <-
        DesiredPresence.reconcileDesiredPresence
          DesiredPresence.DesiredPresenceHooks
            { DesiredPresence.observeDesiredResourcePresence =
                observeAwsSesPresenceWith projectDir awsEnvironment stackConfig
            , DesiredPresence.observeDesiredResourceCheckpoint =
                observeAwsSesCheckpointWith checkpointAdapter checkpointCoordinate
            , DesiredPresence.enactDesiredPresenceAction = \desiredAction -> do
                writeOutputLine
                  ( "AWS SES desired-present action: "
                      ++ renderAwsSesDesiredPresenceAction desiredAction
                  )
                backendResult <-
                  withFencedDecryptedStackEnvironment
                    checkpointAdapter
                    checkpointCoordinate
                    leaseCoordinate
                    legacy
                    awsSesPulumiStackRef
                    baseEnvironment
                    authorizeCheckpoint
                    ( \environment ->
                        runEnsureAwsSesPulumiCycle
                          projectDir
                          environment
                          stackConfig
                    )
                pure (first renderEncryptedBackendError backendResult)
            }
      pure $ case result of
        Left failure ->
          Left
            ( "aws-ses desired-present reconcile refused or failed: "
                ++ show failure
            )
        Right _ -> Right ()

runAwsSesReadinessStage
  :: AwsSesLeaseTransaction -> LeaseGrant -> IO (Either String ())
runAwsSesReadinessStage transaction grant =
  runLeaseWorkAsString
    (awsSesTransactionInterpreter transaction)
    (awsSesTransactionPolicy transaction)
    (awsSesTransactionLeaseCoordinate transaction)
    LeaseReadinessWork
    grant
    ( \permit -> do
        sessionResult <- mintAwsSesWorkSession transaction permit
        case sessionResult of
          Left err -> pure (Left err)
          Right sessionCredentials -> do
            controlPlaneBaseEnvironment <- pulumiSesProviderBaseEnv sessionCredentials
            captureBaseEnvironment <-
              pulumiSesProviderBaseEnv (awsSesTransactionOperationalCredentials transaction)
            let readinessEnvironments =
                  AwsSesReadinessEnvironments
                    { awsSesControlPlaneEnvironment =
                        awsCliCredsFromProviderEnv controlPlaneBaseEnvironment
                    , awsSesCaptureEnvironment =
                        awsCliCredsFromProviderEnv captureBaseEnvironment
                    }
            case awsSesReadinessExpectationForConfig (awsSesTransactionStackConfig transaction) of
              Left err -> pure (Left (Text.pack err))
              Right expectation -> do
                readinessResult <-
                  pollAwsSesReadiness canonicalAwsSesPropagationPolicy $
                    observeAwsSesReadinessAfterProviderPresence
                      transaction
                      readinessEnvironments
                      expectation
                case readinessResult of
                  Left failure ->
                    pure (Left (Text.pack (renderAwsSesReadinessPollFailure failure)))
                  Right () -> do
                    writeOutputLine
                      "AWS SES semantic readiness: exact sender, MX, receipt rule, and operational capture list/get are Ready."
                    pure (Right ())
    )

awsSesReadinessExpectationForConfig
  :: AwsSesStackConfig -> Either String AwsSesReadinessExpectation
awsSesReadinessExpectationForConfig stackConfig =
  mkAwsSesReadinessExpectation
    (sesStackSenderDomain stackConfig)
    (sesStackParentZoneId stackConfig)
    (sesStackAwsRegion stackConfig)
    (sesStackReceiveSubdomain stackConfig)
    (sesStackCaptureBucket stackConfig)

-- | One poll attempt first proves the complete typed provider inventory, then
-- and only then performs semantic reconnaissance.  Missing provider resources
-- are a propagation 'Pending'; inability to observe them is terminal and
-- fail-closed.  Both layers therefore share the same bounded poll and preserve
-- the final structured reason before the enclosing lease-work deadline.
observeAwsSesReadinessAfterProviderPresence
  :: AwsSesLeaseTransaction
  -> AwsSesReadinessEnvironments
  -> AwsSesReadinessExpectation
  -> IO AwsSesReadiness
observeAwsSesReadinessAfterProviderPresence transaction environments expectation = do
  providerThenSemanticReadiness observeProvider observeSemantic
 where
  observeProvider = do
    observed <-
      observeAwsSesPresenceWith
        (awsSesTransactionProjectDir transaction)
        (awsSesControlPlaneEnvironment environments)
        (awsSesTransactionStackConfig transaction)
    pure $
      case observed of
        ResidueStatus.PresencePresent inventory
          | awsSesPresenceInventoryComplete inventory -> AwsSesProviderReady
          | otherwise ->
              AwsSesProviderPending
                ( "registered resources currently visible: "
                    ++ show (awsSesPresentResources inventory)
                )
        ResidueStatus.PresenceAbsent ->
          AwsSesProviderPending "no registered AWS SES resources are currently visible"
        ResidueStatus.PresenceUnobservable failure ->
          AwsSesProviderUnobservable
            ("provider inventory is unobservable: " ++ renderObservationFailure failure)

  observeSemantic =
    observeAwsSesReadiness
      (awsSesTransactionProjectDir transaction)
      environments
      expectation
      AwsSesCompleteReadiness

runAwsSesSmtpStage
  :: AwsSesTargetSelection
  -> AwsSesLeaseTransaction
  -> LeaseGrant
  -> IO (Either String ())
runAwsSesSmtpStage selection transaction grant =
  runLeaseWorkAsString
    (awsSesTransactionInterpreter transaction)
    (awsSesTransactionPolicy transaction)
    (awsSesTransactionLeaseCoordinate transaction)
    LeaseSmtpCommitWork
    grant
    ( \permit -> do
        sessionResult <- mintAwsSesWorkSession transaction permit
        case sessionResult of
          Left err -> pure (Left err)
          Right sessionCredentials -> do
            baseEnvironment <- pulumiSesProviderBaseEnv sessionCredentials
            repairResult <-
              repairAwsSesSmtpCredential
                transaction
                grant
                (awsCliCredsFromProviderEnv baseEnvironment)
            case repairResult of
              Left err -> pure (Left (Text.pack err))
              Right committed ->
                first Text.pack
                  <$> materializeCommittedSmtp
                    transaction
                    selection
                    grant
                    permit
                    committed
    )

repairAwsSesSmtpCredential
  :: AwsSesLeaseTransaction
  -> LeaseGrant
  -> [(String, String)]
  -> IO (Either String SmtpCommittedProjection)
repairAwsSesSmtpCredential transaction grant environment =
  case ( awsSesSmtpCommitCoordinate
           (awsSesTransactionAuthority transaction)
           (awsSesTransactionLeaseKey transaction)
       , mkSmtpKeyInventoryBound 2
       ) of
    (Left err, _) -> pure (Left (show err))
    (_, Left err) -> pure (Left (show err))
    (Right projectionCoordinate, Right inventoryBound) -> do
      let authority = awsSesTransactionAuthority transaction
          leaseCoordinate = awsSesTransactionLeaseCoordinate transaction
          leaseInterpreter = awsSesTransactionInterpreter transaction
          smtpInterpreter =
            SmtpKeyRepairInterpreter
              { smtpKeyRepairModelB =
                  gatewayModelBCasAdapter authority smtpCommittedModelBCodec
              , smtpKeyRepairAuthorityNow = observeGatewayAuthorityTime authority
              , smtpKeyRepairWaitUntil =
                  waitForGatewayAuthorityTime authority leaseRuntimePollMicros
              , smtpKeyRepairObserveInventory =
                  observeAwsSesSmtpKeyInventory
                    (awsSesTransactionProjectDir transaction)
                    environment
              , smtpKeyRepairDeleteKey =
                  deleteAwsSesSmtpAccessKey
                    (awsSesTransactionProjectDir transaction)
                    environment
              , smtpKeyRepairFreshFencedPermit =
                  first (Text.pack . show)
                    <$> fencedCommitPermitWith leaseInterpreter leaseCoordinate grant
              , smtpKeyRepairCreateKey = \_ ->
                  createAwsSesSmtpAccessKey
                    (awsSesTransactionProjectDir transaction)
                    environment
              , smtpKeyRepairDigestMaterial = smtpKeyMaterialDigest
              }
          request =
            SmtpKeyRepairRequest
              { smtpKeyRepairProjectionCoordinate = projectionCoordinate
              , smtpKeyRepairLeaseCoordinate = leaseCoordinate
              , smtpKeyRepairInventoryBound = inventoryBound
              , smtpKeyRepairLeasePolicy = awsSesTransactionPolicy transaction
              }
      result <- runSmtpKeyRepairWith smtpInterpreter request
      pure
        ( first
            (("repair fenced SES SMTP credential: " ++) . show)
            (smtpKeyRepairOutcomeCredential <$> result)
        )

mintAwsSesWorkSession
  :: AwsSesLeaseTransaction
  -> LeaseUsePermit
  -> IO (Either Text.Text Credentials)
mintAwsSesWorkSession transaction permit = do
  case awsSesLeaseRoleArn (leaseKeyAccount (awsSesTransactionLeaseKey transaction)) of
    Left err -> pure (Left (Text.pack (show err)))
    Right roleArn -> do
      result <-
        mintLeaseScopedAwsSession
          (awsSesTransactionAuthority transaction)
          roleArn
          (awsSesTransactionPolicy transaction)
          (awsSesTransactionOperationalCredentials transaction)
          permit
          (leasePolicyGrantTtl (awsSesTransactionPolicy transaction))
      pure (first (Text.pack . show) (leaseScopedAwsCredentials <$> result))

renderAwsSesDesiredPresenceAction
  :: DesiredPresence.DesiredPresenceAction AwsSesPresenceInventory AwsSesCheckpointSnapshot
  -> String
renderAwsSesDesiredPresenceAction action = case action of
  DesiredPresence.CreateFromAbsentMissingCheckpoint ->
    "create (AWS absent, checkpoint missing)"
  DesiredPresence.CreateFromAbsentValidCheckpoint _ ->
    "create/reconcile (AWS absent, checkpoint valid)"
  DesiredPresence.CreateFromAbsentCorruptCheckpoint _ ->
    "create and replace corrupt checkpoint"
  DesiredPresence.ImportPresentMissingCheckpoint _ ->
    "import live AWS inventory into missing checkpoint"
  DesiredPresence.ReconcilePresentValidCheckpoint _ _ ->
    "reconcile live AWS inventory with valid checkpoint"
  DesiredPresence.RepairPresentCorruptCheckpoint _ _ ->
    "repair corrupt checkpoint from live AWS inventory"

runEnsureAwsSesPulumiCycle
  :: FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (Either String ())
runEnsureAwsSesPulumiCycle projectDir baseEnvironment stackConfig = do
  loginExit <- pulumiLogin projectDir baseEnvironment
  case loginExit of
    ExitFailure _ -> pure (Left "pulumi login failed")
    ExitSuccess -> do
      initialSelect <- pulumiStackSelect projectDir baseEnvironment False
      case initialSelect of
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))
        PulumiStackSelected ->
          runEnsureAwsSesPulumiUp projectDir baseEnvironment stackConfig
        PulumiStackMissing -> do
          createSelect <- pulumiStackSelect projectDir baseEnvironment True
          case createSelect of
            PulumiStackMissing ->
              pure (Left "pulumi stack select reported a missing stack after --create")
            PulumiStackSelectFailed detail ->
              pure (Left ("pulumi stack select failed: " ++ detail))
            PulumiStackSelected -> do
              repairResult <-
                recoverAwsSesPulumiStateFromLiveResources
                  projectDir
                  baseEnvironment
                  stackConfig
              case repairResult of
                Left err -> pure (Left err)
                Right () ->
                  runEnsureAwsSesPulumiUp projectDir baseEnvironment stackConfig

runEnsureAwsSesPulumiUp
  :: FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (Either String ())
runEnsureAwsSesPulumiUp projectDir baseEnvironment stackConfig = do
  syncExit <- syncAwsSesStackConfig projectDir baseEnvironment stackConfig
  case syncExit of
    ExitFailure _ -> pure (Left "pulumi config set failed")
    ExitSuccess -> do
      upExit <- pulumiUp projectDir baseEnvironment
      case upExit of
        ExitFailure _ -> pure (Left "pulumi up failed")
        ExitSuccess -> do
          outputsResult <- pulumiStackOutputs projectDir baseEnvironment
          case outputsResult of
            Left err -> pure (Left err)
            Right outputs ->
              case snapshotFromOutputs outputs of
                Left err -> pure (Left err)
                Right snapshot -> do
                  writeOutput (renderAwsSesStackReport snapshot 0)
                  pure (Right ())

recoverAwsSesPulumiStateFromLiveResources
  :: FilePath -> [(String, String)] -> AwsSesStackConfig -> IO (Either String ())
recoverAwsSesPulumiStateFromLiveResources projectDir scratchEnvironment stackConfig = do
  bucketImport <-
    repairObservedResource
      (AwsSesCaptureBucketProbe (sesStackCaptureBucket stackConfig))
      "AWS SES state repair: importing existing capture bucket into the long-lived Pulumi stack"
      (pure (Right ()))
      "aws:s3/bucket:Bucket"
      "captureBucketResource"
      (sesStackCaptureBucket stackConfig)
  case bucketImport of
    Left err -> pure (Left err)
    Right () -> do
      canaryImport <-
        repairObservedResource
          (AwsSesCaptureReadinessObjectProbe (sesStackCaptureBucket stackConfig))
          "AWS SES state repair: importing the existing capture-readiness object into the long-lived Pulumi stack"
          (pure (Right ()))
          "aws:s3/bucketObjectv2:BucketObjectv2"
          "captureReadinessObject"
          (sesStackCaptureBucket stackConfig ++ "/" ++ sesCaptureReadinessKey)
      case canaryImport of
        Left err -> pure (Left err)
        Right () -> do
          userImport <-
            repairObservedResource
              AwsSesSmtpIamUserProbe
              "AWS SES state repair: importing existing SMTP IAM user into the long-lived Pulumi stack"
              (pure (Right ()))
              "aws:iam/user:User"
              "smtpUser"
              sesSmtpUserName
          case userImport of
            Left err -> pure (Left err)
            Right () -> do
              ruleSetImport <-
                repairObservedResource
                  AwsSesReceiveRuleSetProbe
                  "AWS SES state repair: importing existing SES receipt rule set into the long-lived Pulumi stack"
                  (pure (Right ()))
                  "aws:ses/receiptRuleSet:ReceiptRuleSet"
                  "receiveRuleSet"
                  sesReceiveRuleSetName
              case ruleSetImport of
                Left err -> pure (Left err)
                Right () ->
                  repairObservedResource
                    AwsSesReceiveRuleProbe
                    "AWS SES state repair: importing existing SES receipt rule into the long-lived Pulumi stack"
                    (pure (Right ()))
                    "aws:ses/receiptRule:ReceiptRule"
                    "receiveRule"
                    (sesReceiveRuleSetName ++ ":" ++ sesReceiveRuleName)
 where
  -- Sprint 7.23: the scratch file-backend env strips standard AWS_* creds
  -- ('Prodbox.Pulumi.EncryptedBackend.fileBackendEnvironment'), but state
  -- recovery's live-resource probes (`aws` CLI), `pulumi import` (default aws
  -- provider) need them — otherwise every
  -- probe fails, nothing is imported, and `pulumi up` tries to CREATE
  -- already-live resources (EntityAlreadyExists / AlreadyExists /
  -- BucketAlreadyOwnedByYou). Re-derive AWS_* from the PRODBOX_PULUMI_AWS_*
  -- provider creds that survive in the scratch env.
  environment = awsCliCredsFromProviderEnv scratchEnvironment
  repairObservedResource probe narration beforeImport resourceType resourceName resourceId = do
    observation <- observeAwsSesPresenceProbe projectDir environment probe
    case observation of
      ResidueStatus.PresenceAbsent -> pure (Right ())
      ResidueStatus.PresenceUnobservable failure ->
        pure
          ( Left
              ( "AWS SES state repair refused because presence is unobservable: "
                  ++ renderObservationFailure failure
              )
          )
      ResidueStatus.PresencePresent () -> do
        writeDiagnosticLine narration
        preparation <- beforeImport
        case preparation of
          Left err -> pure (Left err)
          Right () ->
            pulumiImportResource
              projectDir
              environment
              resourceType
              resourceName
              resourceId

pulumiImportResource
  :: FilePath -> [(String, String)] -> String -> String -> String -> IO (Either String ())
pulumiImportResource projectDir environment resourceType resourceName resourceId = do
  result <-
    runPulumiCommandQuiet
      projectDir
      environment
      [ "import"
      , "--yes"
      , "--stack"
      , awsSesStackName
      , "--protect=false"
      , "--non-interactive"
      , "--suppress-outputs"
      , resourceType
      , resourceName
      , resourceId
      ]
  pure $ case result of
    Left err ->
      Left
        ( "pulumi import failed for "
            ++ resourceName
            ++ " ("
            ++ resourceType
            ++ "): "
            ++ err
        )
    Right () -> Right ()

-- | Sprint 7.23: re-derive standard @AWS_*@ credentials from the
-- @PRODBOX_PULUMI_AWS_*@ provider credentials that survive in the scratch
-- file-backend env. The standard @AWS_*@ names are stripped by
-- 'Prodbox.Pulumi.EncryptedBackend.fileBackendEnvironment' (to keep the scratch
-- backend isolated from the object-store credentials), but AWS-SES state
-- recovery's @aws@ CLI probes, @pulumi import@ (default aws provider), and IAM
-- key rotation must authenticate to AWS. Overlays the mapped values onto the
-- env, leaving @PULUMI_BACKEND_URL@ and everything else intact.
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
destroyAwsSesStack repoRoot summary = do
  statusResult <- destroyAwsSesStackStatus repoRoot summary
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS SES stack: " ++ status)
      pure ExitSuccess

-- | Sprint 7.14: aws-ses destroy authenticates the AWS provider with
-- admin credentials (`aws_admin_for_test_simulation.*`) and consults the
-- encrypted scratch backend. The operational @aws.*@ block is no longer
-- read on this path.
destroyAwsSesStackStatus :: FilePath -> Bool -> IO (Either String String)
destroyAwsSesStackStatus repoRoot summary = do
  currentSnapshot <- fetchAwsSesStackSnapshotFromBackend repoRoot
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
          repoRoot
          projectDir
          adminCreds
          backendEnvironment
          (\environment -> runDestroyAwsSesPulumiCycle repoRoot projectDir environment currentSnapshot summary)
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
runDestroyAwsSesPulumiCycle repoRoot projectDir baseEnvironment currentSnapshot summary = do
  loginResult <- pulumiLoginEither projectDir baseEnvironment summary
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
                  destroyResult <- pulumiDestroyEither projectDir baseEnvironment summary
                  case destroyResult of
                    Left err -> pure (Left ("pulumi destroy failed: " ++ err))
                    Right () -> completeDestroy repoRoot projectDir baseEnvironment summary
        PulumiStackMissing ->
          case currentSnapshot of
            Nothing -> pure (Right "already absent from the long-lived Pulumi backend")
            Just _ -> finalizeDestroy
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))

completeDestroy
  :: FilePath -> FilePath -> [(String, String)] -> Bool -> IO (Either String String)
completeDestroy _repoRoot projectDir environment summary = do
  _ <- pulumiStackRemoveEither projectDir environment False summary
  finalizeDestroy

finalizeDestroy :: IO (Either String String)
finalizeDestroy = pure (Right "destroyed")

pulumiLoginEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiLoginEither projectDir environment summary
  | summary = pulumiLoginQuiet projectDir environment
  | otherwise = exitToEither "pulumi login" <$> pulumiLogin projectDir environment

pulumiDestroyEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiDestroyEither projectDir environment summary
  | summary = pulumiDestroyQuiet projectDir environment
  | otherwise =
      exitToEither "pulumi destroy"
        <$> runPulumiCommand
          projectDir
          environment
          ["destroy", "--yes", "--stack", awsSesStackName]

pulumiStackRemoveEither
  :: FilePath -> [(String, String)] -> Bool -> Bool -> IO (Either String ())
pulumiStackRemoveEither projectDir environment force summary
  | summary = pulumiStackRemoveQuiet projectDir environment force
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

-- Residue assertion. After teardown there should be no SES sending domain identity, no
-- active receive rule set referencing the receive subdomain, and no capture S3 bucket on
-- the supported AWS account.
assertNoAwsSesStackResidue :: FilePath -> IO (Either String ())
assertNoAwsSesStackResidue repoRoot = do
  configResult <- resolveAwsSesStackConfig repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right stackConfig -> do
      let captureBucket = sesStackCaptureBucket stackConfig
      bucketResidue <- discoverBucketResidue repoRoot captureBucket
      case bucketResidue of
        Left err -> pure (Left err)
        Right True ->
          pure
            ( Left
                ( "S3 capture bucket `"
                    ++ captureBucket
                    ++ "` still exists after destroy; manual cleanup required"
                )
            )
        Right False -> pure (Right ())

discoverBucketResidue :: FilePath -> String -> IO (Either String Bool)
discoverBucketResidue repoRoot bucketName = do
  envResult <- settingsAwsEnv repoRoot
  case envResult of
    Left err -> pure (Left err)
    Right environment -> do
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "s3api"
                , "head-bucket"
                , "--bucket"
                , bucketName
                ]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Nothing
            }
      pure $ case result of
        Failure err -> Left ("failed to start aws s3api head-bucket: " ++ err)
        Success output ->
          case classifyAwsSesPresenceOutput (AwsSesCaptureBucketProbe bucketName) output of
            ResidueStatus.PresenceAbsent -> Right False
            ResidueStatus.PresencePresent () -> Right True
            ResidueStatus.PresenceUnobservable failure -> Left (renderObservationFailure failure)

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
