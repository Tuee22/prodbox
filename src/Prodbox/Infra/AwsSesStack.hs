{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsSesStack
  ( AwsSesStackSnapshot (..)
  , awsSesStackName
  , keycloakSmtpSecretNamespaces
  , renderKeycloakSmtpKubectlApplyScript
  , ensureAwsSesStackResources
  , syncKeycloakSmtpChartSecrets
  , destroyAwsSesStack
  , awsSesStackResidueStatus
  , assertNoAwsSesStackResidue
  , migrateAwsSesStackBackend
  , renderAwsSesStackReport
  , parseAwsSesStackFromOutputs
  )
where

import Control.Exception (IOException, bracket, try)
import Control.Monad (foldM, forM_, when)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (intercalate, isInfixOf)
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
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack
  ( pulumiAwsProviderEnv
  , settingsAwsEnv
  )
import Prodbox.Infra.LongLivedPulumiBackend
  ( ensureLongLivedPulumiStateBucket
  , loadAdminAwsCredentials
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrlEither
  )
import Prodbox.Infra.MinioBackend
  ( ensureMinioBackendBucket
  , pulumiBackendLoginTimeoutSeconds
  , pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Result (Result (..))
import Prodbox.Ses.SmtpPassword (derivedSesSmtpPassword)
import Prodbox.Settings
  ( ConfigFile
  , Credentials (..)
  , PulumiStateBackendSection
  , Route53Section (..)
  , SesSection (..)
  , aws_admin_for_test_simulation
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
import System.Directory
  ( doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

awsSesStackName :: String
awsSesStackName = "aws-ses"

awsSesPulumiProjectDir :: FilePath -> FilePath
awsSesPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-ses"

sesReceiveRuleSetName :: String
sesReceiveRuleSetName = "prodbox-receive-rule-set"

sesReceiveRuleName :: String
sesReceiveRuleName = "prodbox-capture-all-mail"

sesSmtpUserName :: String
sesSmtpUserName = "prodbox-ses-smtp"

keycloakSmtpSecretName :: String
keycloakSmtpSecretName = "keycloak-smtp"

-- | Namespaces where the Keycloak release can legitimately run on the
-- supported chart surface. `prodbox charts deploy keycloak` renders Keycloak
-- in `keycloak`; the canonical shared-edge stack (`charts deploy vscode`) runs
-- the transitive Keycloak release in `vscode`.
keycloakSmtpSecretNamespaces :: [String]
keycloakSmtpSecretNamespaces = ["vscode", "keycloak"]

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
  , sesSnapshotSendingDomain :: String
  , sesSnapshotReceiveSubdomain :: String
  , sesSnapshotReceiveSubdomainMxFqdn :: String
  , sesSnapshotReceiveRuleSetName :: String
  , sesSnapshotReceiveRuleName :: String
  , sesSnapshotCaptureBucketName :: String
  , sesSnapshotCaptureBucketArn :: String
  , sesSnapshotCaptureBucketKeyPrefix :: String
  , sesSnapshotSmtpEndpoint :: String
  , sesSnapshotSmtpIamUserName :: String
  , sesSnapshotSmtpIamUserArn :: String
  , sesSnapshotSmtpIamAccessKeyId :: String
  }
  deriving (Eq, Show)

data AwsSesStackConfig = AwsSesStackConfig
  { sesStackParentZoneId :: String
  , sesStackSenderDomain :: String
  , sesStackReceiveSubdomain :: String
  , sesStackCaptureBucket :: String
  , sesStackAwsRegion :: String
  }
  deriving (Eq, Show)

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
  sendingDomain <- requireMapString outputs "sending_domain"
  receiveSubdomain <- requireMapString outputs "receive_subdomain"
  receiveSubdomainMxFqdn <- requireMapString outputs "receive_subdomain_mx_fqdn"
  receiveRuleSetName <- requireMapString outputs "receive_rule_set_name"
  receiveRuleName <- requireMapString outputs "receive_rule_name"
  captureBucketName <- requireMapString outputs "capture_bucket_name"
  captureBucketArn <- requireMapString outputs "capture_bucket_arn"
  captureBucketKeyPrefix <- requireMapString outputs "capture_bucket_key_prefix"
  smtpEndpoint <- requireMapString outputs "smtp_endpoint"
  smtpIamUserName <- requireMapString outputs "smtp_iam_user_name"
  smtpIamUserArn <- requireMapString outputs "smtp_iam_user_arn"
  smtpIamAccessKeyId <- requireMapString outputs "smtp_iam_access_key_id"
  Right
    AwsSesStackSnapshot
      { sesSnapshotStackName = awsSesStackName
      , sesSnapshotBackendBucket = backendBucket
      , sesSnapshotSendingDomain = sendingDomain
      , sesSnapshotReceiveSubdomain = receiveSubdomain
      , sesSnapshotReceiveSubdomainMxFqdn = receiveSubdomainMxFqdn
      , sesSnapshotReceiveRuleSetName = receiveRuleSetName
      , sesSnapshotReceiveRuleName = receiveRuleName
      , sesSnapshotCaptureBucketName = captureBucketName
      , sesSnapshotCaptureBucketArn = captureBucketArn
      , sesSnapshotCaptureBucketKeyPrefix = captureBucketKeyPrefix
      , sesSnapshotSmtpEndpoint = smtpEndpoint
      , sesSnapshotSmtpIamUserName = smtpIamUserName
      , sesSnapshotSmtpIamUserArn = smtpIamUserArn
      , sesSnapshotSmtpIamAccessKeyId = smtpIamAccessKeyId
      }

requireMapString :: Map Text.Text Text.Text -> String -> Either String String
requireMapString outputs key =
  case Map.lookup (Text.pack key) outputs of
    Nothing -> Left ("aws-ses Pulumi outputs missing required field '" ++ key ++ "'")
    Just text ->
      let str = Text.unpack text
       in if null str
            then Left ("aws-ses Pulumi outputs field '" ++ key ++ "' is empty")
            else Right str

snapshotFromOutputs :: Value -> Either String AwsSesStackSnapshot
snapshotFromOutputs (Object obj) = do
  backendBucket <- requireString obj "backend_bucket"
  sendingDomain <- requireString obj "sending_domain"
  receiveSubdomain <- requireString obj "receive_subdomain"
  receiveSubdomainMxFqdn <- requireString obj "receive_subdomain_mx_fqdn"
  receiveRuleSetName <- requireString obj "receive_rule_set_name"
  receiveRuleName <- requireString obj "receive_rule_name"
  captureBucketName <- requireString obj "capture_bucket_name"
  captureBucketArn <- requireString obj "capture_bucket_arn"
  captureBucketKeyPrefix <- requireString obj "capture_bucket_key_prefix"
  smtpEndpoint <- requireString obj "smtp_endpoint"
  smtpIamUserName <- requireString obj "smtp_iam_user_name"
  smtpIamUserArn <- requireString obj "smtp_iam_user_arn"
  smtpIamAccessKeyId <- requireString obj "smtp_iam_access_key_id"
  Right
    AwsSesStackSnapshot
      { sesSnapshotStackName = awsSesStackName
      , sesSnapshotBackendBucket = backendBucket
      , sesSnapshotSendingDomain = sendingDomain
      , sesSnapshotReceiveSubdomain = receiveSubdomain
      , sesSnapshotReceiveSubdomainMxFqdn = receiveSubdomainMxFqdn
      , sesSnapshotReceiveRuleSetName = receiveRuleSetName
      , sesSnapshotReceiveRuleName = receiveRuleName
      , sesSnapshotCaptureBucketName = captureBucketName
      , sesSnapshotCaptureBucketArn = captureBucketArn
      , sesSnapshotCaptureBucketKeyPrefix = captureBucketKeyPrefix
      , sesSnapshotSmtpEndpoint = smtpEndpoint
      , sesSnapshotSmtpIamUserName = smtpIamUserName
      , sesSnapshotSmtpIamUserArn = smtpIamUserArn
      , sesSnapshotSmtpIamAccessKeyId = smtpIamAccessKeyId
      }
snapshotFromOutputs _ = Left "aws-ses pulumi output must be a JSON object"

requireString :: KeyMap.KeyMap Value -> String -> Either String String
requireString obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (String text) ->
      let str = Text.unpack text
       in if null str then Left ("missing string output " ++ key) else Right str
    _ -> Left ("missing string output " ++ key)

renderAwsSesStackReport :: AwsSesStackSnapshot -> Int -> String
renderAwsSesStackReport snapshot objectCount =
  unlines
    [ "STACK=" ++ sesSnapshotStackName snapshot
    , "BACKEND_BUCKET=" ++ sesSnapshotBackendBucket snapshot
    , "BACKEND_OBJECT_COUNT=" ++ show objectCount
    , "SENDING_DOMAIN=" ++ sesSnapshotSendingDomain snapshot
    , "RECEIVE_SUBDOMAIN=" ++ sesSnapshotReceiveSubdomain snapshot
    , "RECEIVE_SUBDOMAIN_MX_FQDN=" ++ sesSnapshotReceiveSubdomainMxFqdn snapshot
    , "RECEIVE_RULE_SET_NAME=" ++ sesSnapshotReceiveRuleSetName snapshot
    , "RECEIVE_RULE_NAME=" ++ sesSnapshotReceiveRuleName snapshot
    , "CAPTURE_BUCKET_NAME=" ++ sesSnapshotCaptureBucketName snapshot
    , "CAPTURE_BUCKET_ARN=" ++ sesSnapshotCaptureBucketArn snapshot
    , "CAPTURE_BUCKET_KEY_PREFIX=" ++ sesSnapshotCaptureBucketKeyPrefix snapshot
    , "SMTP_ENDPOINT=" ++ sesSnapshotSmtpEndpoint snapshot
    , "SMTP_IAM_USER_NAME=" ++ sesSnapshotSmtpIamUserName snapshot
    , "SMTP_IAM_USER_ARN=" ++ sesSnapshotSmtpIamUserArn snapshot
    , "SMTP_IAM_ACCESS_KEY_ID=" ++ sesSnapshotSmtpIamAccessKeyId snapshot
    ]

resolveAwsSesStackConfig :: FilePath -> IO (Either String AwsSesStackConfig)
resolveAwsSesStackConfig repoRoot = do
  configResult <- loadConfigFile repoRoot
  pure $ case configResult of
    Left err -> Left err
    Right config -> awsSesStackConfigFromConfig config

awsSesStackConfigFromConfig :: ConfigFile -> Either String AwsSesStackConfig
awsSesStackConfigFromConfig config = do
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
                        "aws_admin_for_test_simulation.region must be set before provisioning the AWS SES stack"
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
  awsRegionValue =
    Text.unpack (Text.strip (region (aws_admin_for_test_simulation config)))

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

-- | Sprint 4.10 admin-credential build: emit the env vars that the
-- aws-ses Pulumi flow needs when state lives on the long-lived S3
-- backend and the AWS provider authenticates with admin credentials
-- (`aws_admin_for_test_simulation.*`). The same admin creds are used
-- both for S3 backend authentication (via the `AWS_*` env vars) and
-- for the AWS Pulumi provider (via the `PRODBOX_PULUMI_AWS_*` env
-- vars). The operational `aws.*` block is no longer read on this
-- path.
pulumiSesAdminBaseEnv
  :: FilePath
  -> Credentials
  -> PulumiStateBackendSection
  -> IO (Either String [(String, String)])
pulumiSesAdminBaseEnv _repoRoot adminCreds backend =
  case longLivedPulumiBackendUrlEither backend of
    Left err -> pure (Left (longLivedBackendErrorMessage err))
    Right backendUrl -> do
      currentEnv <- getEnvironment
      let path = maybe "" id (lookup "PATH" currentEnv)
          home = maybe "" id (lookup "HOME" currentEnv)
          providerEnv = pulumiAwsProviderEnv adminCreds
          adminRegion = Text.unpack (region adminCreds)
          sessionTokenEntries = case session_token adminCreds of
            Just token -> [("AWS_SESSION_TOKEN", Text.unpack token)]
            Nothing -> []
      pure
        ( Right
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
                ++ providerEnv
            )
        )

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
  let arguments = ["stack", "select", awsSesStackName] ++ ["--create" | createIfMissing]
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

-- Fetch the single named stack output with --show-secrets so the IAM
-- secret access key surfaces in plaintext. Used only on the
-- chart-credential persistence path (`persistKeycloakSmtpChartSecrets`)
-- because the captured value derives the SES SMTP password and is then
-- immediately applied to the cluster-owned `keycloak-smtp` Secret. The
-- plaintext value is never persisted to disk by this function.
pulumiStackOutputSecret
  :: FilePath -> [(String, String)] -> String -> IO (Either String String)
pulumiStackOutputSecret projectDir environment outputName = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments =
            [ "stack"
            , "output"
            , outputName
            , "--show-secrets"
            , "--stack"
            , awsSesStackName
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $ case result of
    Failure err -> Left ("failed to run pulumi stack output --show-secrets: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "pulumi stack output --show-secrets failed for "
                ++ outputName
                ++ ": "
                ++ trim (processStderr output)
            )
        ExitSuccess -> Right (trim (processStdout output))

-- | Re-apply the Keycloak SMTP Secret from the already-provisioned long-lived
-- @aws-ses@ stack into the current Kubernetes context. This is intentionally
-- separate from 'ensureAwsSesStackResources': per-run clusters are fresh while
-- the SES stack is retained, so AWS-substrate validation bootstrap must sync
-- the cluster Secret without mutating the long-lived SES resources.
syncKeycloakSmtpChartSecrets :: FilePath -> IO (Either String ())
syncKeycloakSmtpChartSecrets repoRoot = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then pure (Left ("Pulumi AWS SES project missing: " ++ projectDir))
    else do
      configResult <- resolveAwsSesStackConfig repoRoot
      adminResult <- loadAdminAwsCredentials repoRoot
      backendConfigResult <- loadConfigFile repoRoot
      case (configResult, adminResult, backendConfigResult) of
        (Left err, _, _) -> pure (Left err)
        (_, Left err, _) -> pure (Left err)
        (_, _, Left err) -> pure (Left err)
        (Right stackConfig, Right adminCreds, Right backendConfig) -> do
          let backend = pulumi_state_backend backendConfig
          baseEnvResult <- pulumiSesAdminBaseEnv repoRoot adminCreds backend
          case baseEnvResult of
            Left err -> pure (Left err)
            Right baseEnvironment -> do
              bucketResult <- ensureLongLivedPulumiStateBucket repoRoot baseEnvironment backend
              case bucketResult of
                Left err -> pure (Left (longLivedBackendErrorMessage err))
                Right () ->
                  runSyncKeycloakSmtpChartSecrets repoRoot projectDir baseEnvironment stackConfig

runSyncKeycloakSmtpChartSecrets
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (Either String ())
runSyncKeycloakSmtpChartSecrets repoRoot projectDir baseEnvironment stackConfig = do
  loginResult <- pulumiLoginQuiet projectDir baseEnvironment
  case loginResult of
    Left err -> pure (Left ("pulumi login failed: " ++ err))
    Right () -> do
      selectResult <- pulumiStackSelect projectDir baseEnvironment False
      case selectResult of
        PulumiStackMissing ->
          pure
            ( Left
                ( "aws-ses stack is not present in the long-lived backend; "
                    ++ "run `prodbox aws stack aws-ses reconcile` before keycloak-invite validation."
                )
            )
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))
        PulumiStackSelected -> do
          outputsResult <- pulumiStackOutputs projectDir baseEnvironment
          case outputsResult of
            Left err -> pure (Left err)
            Right outputs ->
              case snapshotFromOutputs outputs of
                Left err -> pure (Left err)
                Right snapshot ->
                  persistKeycloakSmtpChartSecrets
                    repoRoot
                    projectDir
                    baseEnvironment
                    stackConfig
                    snapshot

-- After a successful aws-ses Pulumi reconcile, fetch the IAM secret access
-- key for the SMTP user, derive the SES SMTP password via
-- `Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword`, and apply the
-- `keycloak-smtp` @v1.Secret@ in every supported Keycloak release namespace
-- directly via @kubectl@. The Secret carries the seven @KC_SMTP_*@ fields the
-- chart's `configmap.yaml` reads via Helm @lookup@ in `.Release.Namespace` to
-- populate the realm-import @smtpServer@ block. The IAM secret access key never
-- lands on disk.
--
-- Sprint 3.13 chunk 10: replaced the prior
-- @.prodbox-state/charts/keycloak/.secrets.json@ write with a kubectl
-- apply so the cluster Secret is the source-of-truth. @helm.sh/resource-policy:
-- keep@ is stamped on the Secret so a subsequent @charts delete keycloak@
-- does not delete it, matching the pattern from Sprint 2.19's gateway-minio-creds
-- closure. The chart's own @keycloak-smtp@ Secret template is removed in the
-- same chunk so there is no helm-vs-kubectl multi-writer race.
persistKeycloakSmtpChartSecrets
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> AwsSesStackSnapshot
  -> IO (Either String ())
persistKeycloakSmtpChartSecrets _repoRoot projectDir environment stackConfig snapshot = do
  secretResult <- pulumiStackOutputSecret projectDir environment "smtp_iam_secret_access_key"
  case secretResult of
    Left err -> pure (Left err)
    Right smtpSecret -> do
      let region = Text.pack (sesStackAwsRegion stackConfig)
          derivedPassword =
            Text.unpack (derivedSesSmtpPassword region (Text.pack smtpSecret))
          fromAddress = "noreply@" ++ sesStackSenderDomain stackConfig
          fields =
            [ ("KC_SMTP_HOST", sesSnapshotSmtpEndpoint snapshot)
            , ("KC_SMTP_PORT", "587")
            , ("KC_SMTP_FROM", fromAddress)
            , ("KC_SMTP_FROM_DISPLAY_NAME", "prodbox")
            , ("KC_SMTP_REPLY_TO", fromAddress)
            , ("KC_SMTP_USER", sesSnapshotSmtpIamAccessKeyId snapshot)
            , ("KC_SMTP_PASSWORD", derivedPassword)
            ]
      applyKeycloakSmtpKubectlSecret fields

-- | Apply (create-or-update) the @keycloak-smtp@ Secret in the supported
-- Keycloak release namespaces via @kubectl create secret generic …
-- --dry-run=client -o yaml | kubectl apply -f -@. Mirrors
-- 'Prodbox.CLI.Rke2.writeGatewayMinioCredsSecret' from Sprint 2.19 (same
-- @helm.sh/resource-policy: keep@ annotation so @helm uninstall@ doesn't
-- drop the Secret). The kubectl context is the operator's current kubeconfig.
-- The namespace create is idempotent and intentionally happens before the
-- Secret apply so a fresh EKS cluster can receive the SMTP Secret before Helm
-- renders the Keycloak chart and performs its `lookup`.
applyKeycloakSmtpKubectlSecret :: [(String, String)] -> IO (Either String ())
applyKeycloakSmtpKubectlSecret fields = do
  let script = renderKeycloakSmtpKubectlApplyScript fields
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "sh"
        , subprocessArguments = ["-c", script]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Failure err ->
      Left ("failed to kubectl-apply keycloak-smtp Secret: " ++ err)
    Success output ->
      case processExitCode output of
        ExitSuccess -> Right ()
        ExitFailure _ ->
          Left
            ( "kubectl apply for keycloak-smtp Secret failed: "
                ++ trim (processStderr output ++ processStdout output)
                ++ " (is `kubectl` configured for the operator cluster? "
                ++ "run `prodbox rke2 reconcile` or the AWS-substrate bootstrap first.)"
            )

renderKeycloakSmtpKubectlApplyScript :: [(String, String)] -> String
renderKeycloakSmtpKubectlApplyScript fields =
  intercalate " && " (concatMap namespaceSteps keycloakSmtpSecretNamespaces)
 where
  literalArgs =
    concatMap
      (\(k, v) -> " --from-literal=" ++ shellQuoteForBash (k ++ "=" ++ v))
      fields

  namespaceSteps namespace =
    [ "kubectl create namespace "
        ++ shellQuoteForBash namespace
        ++ " --dry-run=client -o yaml | kubectl apply -f -"
    , "kubectl label namespace "
        ++ shellQuoteForBash namespace
        ++ " "
        ++ shellQuoteForBash "app.kubernetes.io/managed-by=Helm"
        ++ " --overwrite"
    , "kubectl annotate namespace "
        ++ shellQuoteForBash namespace
        ++ " "
        ++ shellQuoteForBash "meta.helm.sh/release-name=gateway"
        ++ " "
        ++ shellQuoteForBash "meta.helm.sh/release-namespace=gateway"
        ++ " "
        ++ shellQuoteForBash "helm.sh/resource-policy=keep"
        ++ " --overwrite"
    , "kubectl create secret generic "
        ++ shellQuoteForBash keycloakSmtpSecretName
        ++ literalArgs
        ++ " -n "
        ++ shellQuoteForBash namespace
        ++ " --dry-run=client -o yaml | kubectl apply -f -"
    , "kubectl annotate secret "
        ++ shellQuoteForBash keycloakSmtpSecretName
        ++ " -n "
        ++ shellQuoteForBash namespace
        ++ " helm.sh/resource-policy=keep --overwrite"
    ]

-- | Shell-quote a literal for safe inclusion as a single argument inside an
-- @sh -c@ script. Wraps in single quotes and escapes embedded single quotes
-- via the @'\\''@ idiom. Mirrors 'Prodbox.CLI.Rke2.shellQuote' but kept
-- local to avoid the import cycle.
shellQuoteForBash :: String -> String
shellQuoteForBash s = "'" ++ concatMap escape s ++ "'"
 where
  escape '\'' = "'\\''"
  escape c = [c]

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

-- | Sprint 4.10: aws-ses Pulumi reconcile authenticates with the
-- admin credential block (`aws_admin_for_test_simulation.*`) and
-- consults the long-lived S3 backend named by
-- `pulumi_state_backend`. The in-cluster MinIO backend is no longer
-- read on this path; operators with existing MinIO-backed state must
-- run `prodbox aws stack aws-ses migrate-backend` once to copy state
-- onto the long-lived bucket.
ensureAwsSesStackResources :: FilePath -> IO ExitCode
ensureAwsSesStackResources repoRoot = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then failWith ("Pulumi AWS SES project missing: " ++ projectDir)
    else do
      configResult <- resolveAwsSesStackConfig repoRoot
      adminResult <- loadAdminAwsCredentials repoRoot
      backendConfigResult <- loadConfigFile repoRoot
      case (configResult, adminResult, backendConfigResult) of
        (Left err, _, _) -> failWith err
        (_, Left err, _) -> failWith err
        (_, _, Left err) -> failWith err
        (Right stackConfig, Right adminCreds, Right backendConfig) -> do
          let backend = pulumi_state_backend backendConfig
          baseEnvResult <- pulumiSesAdminBaseEnv repoRoot adminCreds backend
          case baseEnvResult of
            Left err -> failWith err
            Right baseEnvironment -> do
              bucketResult <-
                ensureLongLivedPulumiStateBucket repoRoot baseEnvironment backend
              case bucketResult of
                Left err -> failWith (longLivedBackendErrorMessage err)
                Right () -> do
                  runResult <-
                    runEnsureAwsSesPulumiCycle
                      repoRoot
                      projectDir
                      baseEnvironment
                      stackConfig
                  case runResult of
                    Left err -> failWith err
                    Right () -> pure ExitSuccess

runEnsureAwsSesPulumiCycle
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (Either String ())
runEnsureAwsSesPulumiCycle repoRoot projectDir baseEnvironment stackConfig = do
  loginExit <- pulumiLogin projectDir baseEnvironment
  case loginExit of
    ExitFailure _ -> pure (Left "pulumi login failed")
    ExitSuccess -> do
      initialSelect <- pulumiStackSelect projectDir baseEnvironment False
      case initialSelect of
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))
        PulumiStackSelected ->
          runEnsureAwsSesPulumiUp repoRoot projectDir baseEnvironment stackConfig
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
                  runEnsureAwsSesPulumiUp repoRoot projectDir baseEnvironment stackConfig

runEnsureAwsSesPulumiUp
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> IO (Either String ())
runEnsureAwsSesPulumiUp repoRoot projectDir baseEnvironment stackConfig = do
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
                  persistResult <-
                    persistKeycloakSmtpChartSecrets
                      repoRoot
                      projectDir
                      baseEnvironment
                      stackConfig
                      snapshot
                  case persistResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      writeOutput (renderAwsSesStackReport snapshot 0)
                      pure (Right ())

recoverAwsSesPulumiStateFromLiveResources
  :: FilePath -> [(String, String)] -> AwsSesStackConfig -> IO (Either String ())
recoverAwsSesPulumiStateFromLiveResources projectDir environment stackConfig = do
  bucketExists <-
    awsCommandSucceeds
      projectDir
      environment
      ["s3api", "head-bucket", "--bucket", sesStackCaptureBucket stackConfig]
  when bucketExists $
    writeDiagnosticLine
      "AWS SES state repair: importing existing capture bucket into the long-lived Pulumi stack"
  bucketImport <-
    importIf
      bucketExists
      "aws:s3/bucket:Bucket"
      "captureBucketResource"
      (sesStackCaptureBucket stackConfig)
  case bucketImport of
    Left err -> pure (Left err)
    Right () -> do
      userExists <-
        awsCommandSucceeds
          projectDir
          environment
          ["iam", "get-user", "--user-name", sesSmtpUserName]
      when userExists $ do
        writeDiagnosticLine
          "AWS SES state repair: rotating stale SMTP IAM access keys before Pulumi creates a managed key"
        deleteExistingSmtpAccessKeysForRepair projectDir environment
        writeDiagnosticLine
          "AWS SES state repair: importing existing SMTP IAM user into the long-lived Pulumi stack"
      userImport <-
        importIf
          userExists
          "aws:iam/user:User"
          "smtpUser"
          sesSmtpUserName
      case userImport of
        Left err -> pure (Left err)
        Right () -> do
          ruleSetExists <-
            awsCommandSucceeds
              projectDir
              environment
              ["ses", "describe-receipt-rule-set", "--rule-set-name", sesReceiveRuleSetName]
          when ruleSetExists $
            writeDiagnosticLine
              "AWS SES state repair: importing existing SES receipt rule set into the long-lived Pulumi stack"
          ruleSetImport <-
            importIf
              ruleSetExists
              "aws:ses/receiptRuleSet:ReceiptRuleSet"
              "receiveRuleSet"
              sesReceiveRuleSetName
          case ruleSetImport of
            Left err -> pure (Left err)
            Right () -> do
              ruleExists <-
                awsCommandSucceeds
                  projectDir
                  environment
                  [ "ses"
                  , "describe-receipt-rule"
                  , "--rule-set-name"
                  , sesReceiveRuleSetName
                  , "--rule-name"
                  , sesReceiveRuleName
                  ]
              when ruleExists $
                writeDiagnosticLine
                  "AWS SES state repair: importing existing SES receipt rule into the long-lived Pulumi stack"
              importIf
                ruleExists
                "aws:ses/receiptRule:ReceiptRule"
                "receiveRule"
                (sesReceiveRuleSetName ++ ":" ++ sesReceiveRuleName)
 where
  importIf False _ _ _ = pure (Right ())
  importIf True resourceType resourceName resourceId =
    pulumiImportResource projectDir environment resourceType resourceName resourceId

deleteExistingSmtpAccessKeysForRepair
  :: FilePath -> [(String, String)] -> IO ()
deleteExistingSmtpAccessKeysForRepair projectDir environment = do
  keysResult <-
    captureAwsText
      projectDir
      environment
      [ "iam"
      , "list-access-keys"
      , "--user-name"
      , sesSmtpUserName
      , "--query"
      , "AccessKeyMetadata[].AccessKeyId"
      , "--output"
      , "text"
      ]
  case keysResult of
    Left err ->
      writeDiagnosticLine ("AWS SES state repair: unable to list stale SMTP keys: " ++ err)
    Right keys ->
      forM_ (words keys) $ \keyId -> do
        deleteResult <-
          awsCommandResult
            projectDir
            environment
            [ "iam"
            , "delete-access-key"
            , "--user-name"
            , sesSmtpUserName
            , "--access-key-id"
            , keyId
            ]
        case deleteResult of
          Right () -> pure ()
          Left err ->
            writeDiagnosticLine
              ("AWS SES state repair: failed to delete stale SMTP key before retry: " ++ err)

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

awsCommandSucceeds :: FilePath -> [(String, String)] -> [String] -> IO Bool
awsCommandSucceeds workingDir environment arguments = do
  result <- awsCommandResult workingDir environment arguments
  pure $ case result of
    Right () -> True
    Left _ -> False

awsCommandResult :: FilePath -> [(String, String)] -> [String] -> IO (Either String ())
awsCommandResult workingDir environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  pure $ case result of
    Failure err -> Left ("failed to start aws: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure code ->
        Left
          ( "aws "
              ++ unwords arguments
              ++ " exited with code "
              ++ show code
              ++ ": "
              ++ trim (processStderr output ++ processStdout output)
          )

captureAwsText :: FilePath -> [(String, String)] -> [String] -> IO (Either String String)
captureAwsText workingDir environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  pure $ case result of
    Failure err -> Left ("failed to start aws: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure code ->
        Left
          ( "aws "
              ++ unwords arguments
              ++ " exited with code "
              ++ show code
              ++ ": "
              ++ trim (processStderr output ++ processStdout output)
          )

destroyAwsSesStack :: FilePath -> Bool -> IO ExitCode
destroyAwsSesStack repoRoot summary = do
  statusResult <- destroyAwsSesStackStatus repoRoot summary
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS SES stack: " ++ status)
      pure ExitSuccess

-- | Sprint 4.10: aws-ses destroy authenticates with admin credentials
-- (`aws_admin_for_test_simulation.*`) and consults the long-lived S3
-- backend. The operational @aws.*@ block is no longer read on this
-- path. The MinIO port-forward is gone — a missing long-lived bucket
-- is treated as "already destroyed" only when no on-disk snapshot
-- exists; otherwise it is an actionable failure.
destroyAwsSesStackStatus :: FilePath -> Bool -> IO (Either String String)
destroyAwsSesStackStatus repoRoot summary = do
  currentSnapshot <- fetchAwsSesStackSnapshotFromBackend repoRoot
  let projectDir = awsSesPulumiProjectDir repoRoot
  adminResult <- loadAdminAwsCredentials repoRoot
  configResult <- loadConfigFile repoRoot
  case (adminResult, configResult) of
    (Left err, _) ->
      case currentSnapshot of
        Nothing ->
          pure
            (Right "no admin AWS credentials configured and no saved residue snapshot; nothing to destroy")
        Just _ -> pure (Left ("admin AWS credentials required to destroy the AWS SES stack: " ++ err))
    (_, Left err) -> pure (Left err)
    (Right adminCreds, Right config) -> do
      let backend = pulumi_state_backend config
      baseEnvResult <- pulumiSesAdminBaseEnv repoRoot adminCreds backend
      case baseEnvResult of
        Left err -> pure (Left err)
        Right backendEnvironment ->
          runDestroyAwsSesPulumiCycle repoRoot projectDir backendEnvironment currentSnapshot summary

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
          case processExitCode output of
            ExitSuccess -> Right True
            ExitFailure _ -> Right False

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | Sprint 4.10: migrate the @aws-ses@ stack's Pulumi state from the
-- in-cluster MinIO backend onto the dedicated long-lived S3 bucket
-- named by @pulumi_state_backend@ in @prodbox-config.dhall@.
-- Idempotent: detects whether the long-lived backend already carries
-- a recent state checkpoint and short-circuits without exporting.
--
-- Operator-driven: gated by 'requireInteractiveTty' at the CLI layer
-- (see 'Prodbox.CLI.Interactive.awsSesMigrateBackendGuard'). The
-- migration sequence follows the doctrine in
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 2@:
--
--   1. Validate that @pulumi_state_backend.bucket_name@ and
--      @pulumi_state_backend.region@ are non-empty (no fallback).
--   2. Ensure the long-lived S3 bucket exists (idempotent
--      @head-bucket@ + @create-bucket@ with versioning, SSE,
--      block-public-access, prodbox tags, and a 90-day
--      noncurrent-version expiration lifecycle rule).
--   3. Detect whether the long-lived backend already carries the
--      stack's checkpoint; short-circuit if so.
--   4. Export the stack from MinIO, log in to the S3 backend, import
--      into S3.
--   5. Persist the operator-visible status report.
migrateAwsSesStackBackend :: FilePath -> IO ExitCode
migrateAwsSesStackBackend repoRoot = do
  requireInteractiveTty awsSesMigrateBackendGuard
  adminResult <- loadAdminAwsCredentials repoRoot
  configResult <- loadConfigFile repoRoot
  case (adminResult, configResult) of
    (Left err, _) -> failWith err
    (_, Left err) -> failWith err
    (Right adminCreds, Right config) -> do
      let backend = pulumi_state_backend config
          projectDir = awsSesPulumiProjectDir repoRoot
      writeOutputLine "AWS_SES_BACKEND_MIGRATION"
      longLivedEnvResult <- pulumiSesAdminBaseEnv repoRoot adminCreds backend
      case longLivedEnvResult of
        Left err -> failWith err
        Right longLivedEnv -> do
          bucketResult <-
            ensureLongLivedPulumiStateBucket repoRoot longLivedEnv backend
          case bucketResult of
            Left err -> failWith (longLivedBackendErrorMessage err)
            Right () -> runMigrateAwsSesBackend repoRoot projectDir longLivedEnv

-- | Idempotent migrate-backend orchestration body. Returns
-- 'ExitSuccess' both when the migration runs to completion AND when
-- it short-circuits because the long-lived backend already carries
-- the stack (subsequent re-runs are no-ops).
runMigrateAwsSesBackend
  :: FilePath -> FilePath -> [(String, String)] -> IO ExitCode
runMigrateAwsSesBackend repoRoot projectDir longLivedEnv = do
  loginExit <- pulumiLogin projectDir longLivedEnv
  case loginExit of
    ExitFailure _ -> failWith "pulumi login against long-lived backend failed"
    ExitSuccess -> do
      selectExit <- pulumiStackSelect projectDir longLivedEnv False
      case selectExit of
        PulumiStackSelected -> do
          writeOutputLine
            "long-lived backend already carries the aws-ses stack; nothing to migrate"
          writeOutputLine "STATUS=already-migrated"
          pure ExitSuccess
        PulumiStackSelectFailed detail ->
          failWith ("pulumi stack select on long-lived backend failed: " ++ detail)
        PulumiStackMissing ->
          performAwsSesBackendMigration repoRoot projectDir longLivedEnv

-- | Drive the export-from-MinIO → import-into-long-lived sequence.
-- Brackets a temporary JSON file holding the exported checkpoint;
-- the file is removed even on failure paths.
performAwsSesBackendMigration
  :: FilePath -> FilePath -> [(String, String)] -> IO ExitCode
performAwsSesBackendMigration repoRoot projectDir longLivedEnv = do
  temporaryDirectory <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile temporaryDirectory "aws-ses-export-.json"
        hClose handle
        pure path
    )
    ( \tempPath -> do
        _ <- try (removeFile tempPath) :: IO (Either IOException ())
        pure ()
    )
    ( \exportFile -> do
        exportResult <- exportAwsSesFromMinIO repoRoot projectDir exportFile
        case exportResult of
          ExitFailure code -> pure (ExitFailure code)
          ExitSuccess -> importAwsSesIntoLongLived projectDir longLivedEnv exportFile
    )

-- | Open a MinIO port-forward, log in to the in-cluster MinIO Pulumi
-- backend, select the aws-ses stack, and export its checkpoint to
-- the supplied file path.
exportAwsSesFromMinIO :: FilePath -> FilePath -> FilePath -> IO ExitCode
exportAwsSesFromMinIO _repoRoot projectDir exportFile = do
  portForwardResult <- withMinioPortForward $ \localPort -> do
    credsResult <- readMinioCredentials
    case credsResult of
      Left err -> pure (Left err)
      Right (accessKey, secretKey) -> do
        bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
        case bucketResult of
          Left err -> pure (Left err)
          Right () -> do
            currentEnv <- getEnvironment
            let path = maybe "" id (lookup "PATH" currentEnv)
                home = maybe "" id (lookup "HOME" currentEnv)
                minioEnv =
                  [ ("AWS_ACCESS_KEY_ID", accessKey)
                  , ("AWS_SECRET_ACCESS_KEY", secretKey)
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
            loginExit <- pulumiLogin projectDir minioEnv
            case loginExit of
              ExitFailure _ -> pure (Left "pulumi login against MinIO backend failed")
              ExitSuccess -> do
                selectExit <- pulumiStackSelect projectDir minioEnv False
                case selectExit of
                  PulumiStackMissing ->
                    pure (Left "aws-ses stack is absent from the MinIO backend; nothing to migrate")
                  PulumiStackSelectFailed detail ->
                    pure (Left ("pulumi stack select on MinIO backend failed: " ++ detail))
                  PulumiStackSelected -> do
                    exportExit <- pulumiStackExport projectDir minioEnv exportFile
                    pure $ case exportExit of
                      ExitSuccess -> Right ()
                      ExitFailure code ->
                        Left ("pulumi stack export from MinIO failed with exit code " ++ show code)
  case portForwardResult of
    Left err -> failWith ("MinIO port-forward unavailable for migration export: " ++ err)
    Right (Left err) -> failWith err
    Right (Right ()) -> pure ExitSuccess

-- | Already authenticated against the long-lived backend (the
-- caller invoked @pulumi login@ against it). Create the @aws-ses@
-- stack and import the checkpoint from the supplied file.
importAwsSesIntoLongLived
  :: FilePath -> [(String, String)] -> FilePath -> IO ExitCode
importAwsSesIntoLongLived projectDir longLivedEnv exportFile = do
  selectExit <- pulumiStackSelect projectDir longLivedEnv True
  case selectExit of
    PulumiStackMissing ->
      failWith "pulumi stack select reported a missing stack after --create on long-lived backend"
    PulumiStackSelectFailed detail ->
      failWith ("pulumi stack --create on long-lived backend failed: " ++ detail)
    PulumiStackSelected -> do
      importExit <- pulumiStackImport projectDir longLivedEnv exportFile
      case importExit of
        ExitFailure code ->
          failWith ("pulumi stack import into long-lived backend failed with exit code " ++ show code)
        ExitSuccess -> do
          writeOutputLine "stack migrated from MinIO backend onto the long-lived S3 backend"
          writeOutputLine "STATUS=migrated"
          pure ExitSuccess

pulumiStackExport :: FilePath -> [(String, String)] -> FilePath -> IO ExitCode
pulumiStackExport projectDir environment outputFile =
  runPulumiCommand
    projectDir
    environment
    ["stack", "export", "--stack", awsSesStackName, "--file", outputFile]

pulumiStackImport :: FilePath -> [(String, String)] -> FilePath -> IO ExitCode
pulumiStackImport projectDir environment inputFile =
  runPulumiCommand
    projectDir
    environment
    ["stack", "import", "--stack", awsSesStackName, "--file", inputFile]
