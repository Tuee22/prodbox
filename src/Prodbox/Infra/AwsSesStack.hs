{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsSesStack
  ( AwsSesStackSnapshot (..)
  , awsSesStackName
  , keycloakSmtpVaultFields
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

import Control.Monad (foldM, forM_, when)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (isInfixOf)
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
  ( loadAdminAwsCredentials
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrlEither
  )
import Prodbox.Infra.MinioBackend
  ( pulumiBackendLoginTimeoutSeconds
  )
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError
  , LegacyPulumiBackend (..)
  , PulumiStackRef (..)
  , renderEncryptedBackendError
  , withDecryptedStackEnvironment
  , withMigratedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
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
import Prodbox.Vault.Host (writeHostVaultKvObject)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

awsSesStackName :: String
awsSesStackName = "aws-ses"

awsSesPulumiStackRef :: PulumiStackRef
awsSesPulumiStackRef =
  PulumiStackRef "prodbox-aws-ses" (Text.pack awsSesStackName)

awsSesPulumiProjectDir :: FilePath -> FilePath
awsSesPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-ses"

sesReceiveRuleSetName :: String
sesReceiveRuleSetName = "prodbox-receive-rule-set"

sesReceiveRuleName :: String
sesReceiveRuleName = "prodbox-capture-all-mail"

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

-- | Sprint 7.16: the SES stack's AWS region now comes from the EPHEMERAL admin
-- credential acquired through 'loadAdminAwsCredentials' (test-secrets.dhall's
-- @aws_admin_for_test_simulation@ block, or the interactive prompt), not from a
-- @prodbox.dhall@ field. The production config still supplies the
-- Route 53 zone, sender domain, receive subdomain, and capture bucket.
resolveAwsSesStackConfig :: FilePath -> IO (Either String AwsSesStackConfig)
resolveAwsSesStackConfig repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> do
      adminResult <- loadAdminAwsCredentials repoRoot
      pure $ case adminResult of
        Left err -> Left err
        Right adminCreds ->
          awsSesStackConfigFromConfig config (Text.unpack (Text.strip (region adminCreds)))

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

-- Fetch the single named stack output with --show-secrets so the IAM
-- secret access key surfaces in plaintext. Used only on the
-- Vault-credential persistence path (`persistKeycloakSmtpChartSecrets`)
-- because the captured value derives the SES SMTP password and is then
-- immediately written to the externally-owned `secret/keycloak/smtp` KV object. The
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

-- | Re-apply the Keycloak SMTP Vault object from the already-provisioned long-lived
-- @aws-ses@ stack into the current cluster's Vault. This is intentionally
-- separate from 'ensureAwsSesStackResources': per-run clusters are fresh while
-- the SES stack is retained, so AWS-substrate validation bootstrap must sync
-- the Vault KV object without mutating the long-lived SES resources.
syncKeycloakSmtpChartSecrets :: FilePath -> IO (Either String ())
syncKeycloakSmtpChartSecrets repoRoot = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then pure (Left ("Pulumi AWS SES project missing: " ++ projectDir))
    else do
      configResult <- resolveAwsSesStackConfig repoRoot
      adminResult <- loadAdminAwsCredentials repoRoot
      case (configResult, adminResult) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right stackConfig, Right adminCreds) -> do
          baseEnvironment <- pulumiSesProviderBaseEnv adminCreds
          backendResult <-
            withAwsSesEncryptedStackEnvironment
              repoRoot
              projectDir
              adminCreds
              baseEnvironment
              (\environment -> runSyncKeycloakSmtpChartSecrets repoRoot projectDir environment stackConfig)
          pure $ case backendResult of
            Left err -> Left (renderEncryptedBackendError err)
            Right () -> Right ()

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
-- `Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword`, and write the
-- externally-owned @secret/keycloak/smtp@ Vault KV object. The Keycloak chart
-- and operator invite helpers read the same Vault object; no kubectl-applied
-- SMTP Secret is a supported source of truth. The IAM secret access key never
-- lands on disk.
--
-- Sprint 3.18: the Sprint 3.13 Kubernetes Secret sync is replaced by a Vault
-- KV write so the SMTP credential has one store before Keycloak starts.
persistKeycloakSmtpChartSecrets
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> AwsSesStackConfig
  -> AwsSesStackSnapshot
  -> IO (Either String ())
persistKeycloakSmtpChartSecrets repoRoot projectDir environment stackConfig snapshot = do
  secretResult <- pulumiStackOutputSecret projectDir environment "smtp_iam_secret_access_key"
  case secretResult of
    Left err -> pure (Left err)
    Right smtpSecret -> do
      writeHostVaultKvObject
        repoRoot
        "secret"
        "keycloak/smtp"
        ( keycloakSmtpVaultFields
            (sesStackAwsRegion stackConfig)
            (sesStackSenderDomain stackConfig)
            (sesSnapshotSmtpEndpoint snapshot)
            (sesSnapshotSmtpIamAccessKeyId snapshot)
            smtpSecret
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

-- | Sprint 7.14: aws-ses Pulumi reconcile authenticates the AWS provider
-- with the admin credential block (`aws_admin_for_test_simulation.*`) and
-- stores Pulumi state through the encrypted scratch backend. The legacy
-- long-lived S3 backend path survives only as an optional first-touch
-- migration source for the encrypted wrapper.
ensureAwsSesStackResources :: FilePath -> IO ExitCode
ensureAwsSesStackResources repoRoot = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then failWith ("Pulumi AWS SES project missing: " ++ projectDir)
    else do
      configResult <- resolveAwsSesStackConfig repoRoot
      adminResult <- loadAdminAwsCredentials repoRoot
      case (configResult, adminResult) of
        (Left err, _) -> failWith err
        (_, Left err) -> failWith err
        (Right stackConfig, Right adminCreds) -> do
          baseEnvironment <- pulumiSesProviderBaseEnv adminCreds
          runResult <-
            withAwsSesEncryptedStackEnvironment
              repoRoot
              projectDir
              adminCreds
              baseEnvironment
              (\environment -> runEnsureAwsSesPulumiCycle repoRoot projectDir environment stackConfig)
          case runResult of
            Left err -> failWith (renderEncryptedBackendError err)
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
recoverAwsSesPulumiStateFromLiveResources projectDir scratchEnvironment stackConfig = do
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
  -- Sprint 7.23: the scratch file-backend env strips standard AWS_* creds
  -- ('Prodbox.Pulumi.EncryptedBackend.fileBackendEnvironment'), but state
  -- recovery's live-resource probes (`aws` CLI), `pulumi import` (default aws
  -- provider), and stale-IAM-key rotation all need them — otherwise every
  -- probe fails, nothing is imported, and `pulumi up` tries to CREATE
  -- already-live resources (EntityAlreadyExists / AlreadyExists /
  -- BucketAlreadyOwnedByYou). Re-derive AWS_* from the PRODBOX_PULUMI_AWS_*
  -- provider creds that survive in the scratch env.
  environment = awsCliCredsFromProviderEnv scratchEnvironment
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
          case processExitCode output of
            ExitSuccess -> Right True
            ExitFailure _ -> Right False

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
