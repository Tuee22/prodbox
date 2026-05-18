{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsSesStack
  ( AwsSesStackSnapshot (..)
  , awsSesStackName
  , ensureAwsSesStackResources
  , destroyAwsSesStack
  , loadAwsSesStackSnapshot
  , saveAwsSesStackSnapshot
  , clearAwsSesStackSnapshot
  , assertNoAwsSesStackResidue
  , renderAwsSesStackReport
  )
where

import Control.Monad (foldM)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack
  ( loadOperationalAwsCredentials
  , pulumiAwsProviderEnv
  , pulumiBackendBaseEnv
  , settingsAwsEnv
  )
import Prodbox.Infra.MinioBackend
  ( bucketObjectCount
  , ensureMinioBackendBucket
  , pulumiBackendLoginTimeoutSeconds
  , pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( Route53Section (..)
  , SesSection (..)
  , ValidatedSettings (..)
  , aws
  , route53
  , ses
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

awsSesStackName :: String
awsSesStackName = "aws-ses"

awsSesPulumiProjectDir :: FilePath -> FilePath
awsSesPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-ses"

awsSesStateDir :: FilePath -> FilePath
awsSesStateDir repoRoot = repoRoot </> ".prodbox-state" </> awsSesStackName

awsSesSnapshotPath :: FilePath -> FilePath
awsSesSnapshotPath repoRoot = awsSesStateDir repoRoot </> "stack-snapshot.json"

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
  }
  deriving (Eq, Show)

saveAwsSesStackSnapshot :: FilePath -> AwsSesStackSnapshot -> IO ()
saveAwsSesStackSnapshot repoRoot snapshot = do
  createDirectoryIfMissing True (awsSesStateDir repoRoot)
  BL.writeFile (awsSesSnapshotPath repoRoot) (encode (snapshotToJson snapshot))

loadAwsSesStackSnapshot :: FilePath -> IO (Maybe AwsSesStackSnapshot)
loadAwsSesStackSnapshot repoRoot = do
  let snapshotPath = awsSesSnapshotPath repoRoot
  exists <- doesFileExist snapshotPath
  if not exists
    then pure Nothing
    else do
      contents <- BL.readFile snapshotPath
      case eitherDecode contents of
        Left _ -> pure Nothing
        Right value ->
          case snapshotFromJson value of
            Left _ -> pure Nothing
            Right snapshot -> pure (Just snapshot)

clearAwsSesStackSnapshot :: FilePath -> IO ()
clearAwsSesStackSnapshot repoRoot = do
  let snapshotPath = awsSesSnapshotPath repoRoot
  exists <- doesFileExist snapshotPath
  if exists then removeFile snapshotPath else pure ()

snapshotToJson :: AwsSesStackSnapshot -> Value
snapshotToJson snapshot =
  object
    [ "stack_name" .= sesSnapshotStackName snapshot
    , "backend_bucket" .= sesSnapshotBackendBucket snapshot
    , "sending_domain" .= sesSnapshotSendingDomain snapshot
    , "receive_subdomain" .= sesSnapshotReceiveSubdomain snapshot
    , "receive_subdomain_mx_fqdn" .= sesSnapshotReceiveSubdomainMxFqdn snapshot
    , "receive_rule_set_name" .= sesSnapshotReceiveRuleSetName snapshot
    , "receive_rule_name" .= sesSnapshotReceiveRuleName snapshot
    , "capture_bucket_name" .= sesSnapshotCaptureBucketName snapshot
    , "capture_bucket_arn" .= sesSnapshotCaptureBucketArn snapshot
    , "capture_bucket_key_prefix" .= sesSnapshotCaptureBucketKeyPrefix snapshot
    , "smtp_endpoint" .= sesSnapshotSmtpEndpoint snapshot
    , "smtp_iam_user_name" .= sesSnapshotSmtpIamUserName snapshot
    , "smtp_iam_user_arn" .= sesSnapshotSmtpIamUserArn snapshot
    , "smtp_iam_access_key_id" .= sesSnapshotSmtpIamAccessKeyId snapshot
    ]

snapshotFromJson :: Value -> Either String AwsSesStackSnapshot
snapshotFromJson (Object obj) = do
  stackName <- requireString obj "stack_name"
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
      { sesSnapshotStackName = stackName
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
snapshotFromJson _ = Left "aws-ses snapshot must be a JSON object"

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
  settingsResult <- validateAndLoadSettings repoRoot
  pure $ case settingsResult of
    Left err -> Left err
    Right settings ->
      let parentZoneId = Text.unpack (Text.strip (zone_id (route53 (validatedConfig settings))))
          sesSection = ses (validatedConfig settings)
          senderDomainValue = Text.unpack (Text.strip (sender_domain sesSection))
          receiveSubdomainValue = Text.unpack (Text.strip (receive_subdomain sesSection))
          captureBucketValue = Text.unpack (Text.strip (capture_bucket sesSection))
       in if null parentZoneId
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
                          Right
                            AwsSesStackConfig
                              { sesStackParentZoneId = parentZoneId
                              , sesStackSenderDomain = senderDomainValue
                              , sesStackReceiveSubdomain = receiveSubdomainValue
                              , sesStackCaptureBucket = captureBucketValue
                              }

syncAwsSesStackConfig :: FilePath -> [(String, String)] -> AwsSesStackConfig -> IO ExitCode
syncAwsSesStackConfig projectDir environment stackConfig =
  foldM runConfigSet ExitSuccess configEntries
 where
  configEntries =
    [ ("parentZoneId", sesStackParentZoneId stackConfig)
    , ("senderDomain", sesStackSenderDomain stackConfig)
    , ("receiveSubdomain", sesStackReceiveSubdomain stackConfig)
    , ("captureBucket", sesStackCaptureBucket stackConfig)
    ]

  runConfigSet :: ExitCode -> (String, String) -> IO ExitCode
  runConfigSet failure@(ExitFailure _) _ = pure failure
  runConfigSet ExitSuccess (key, value) =
    runPulumiCommand
      projectDir
      environment
      ["config", "set", "--stack", awsSesStackName, key, value]

pulumiSesBaseEnv :: FilePath -> Int -> String -> String -> IO (Either String [(String, String)])
pulumiSesBaseEnv repoRoot localPort minioAccessKey minioSecretKey = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left err)
    Right settings -> do
      currentEnv <- getEnvironment
      let path = maybe "" id (lookup "PATH" currentEnv)
          home = maybe "" id (lookup "HOME" currentEnv)
          providerEnv = pulumiAwsProviderEnv (aws (validatedConfig settings))
      pure
        ( Right
            ( [ ("AWS_ACCESS_KEY_ID", minioAccessKey)
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

ensureAwsSesStackResources :: FilePath -> IO ExitCode
ensureAwsSesStackResources repoRoot = do
  let projectDir = awsSesPulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then failWith ("Pulumi AWS SES project missing: " ++ projectDir)
    else do
      configResult <- resolveAwsSesStackConfig repoRoot
      case configResult of
        Left err -> failWith err
        Right stackConfig -> do
          portForwardResult <- withMinioPortForward $ \localPort -> do
            credsResult <- readMinioCredentials
            case credsResult of
              Left err -> pure (Left err)
              Right (accessKey, secretKey) -> do
                bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
                case bucketResult of
                  Left err -> pure (Left err)
                  Right () -> do
                    baseEnvironmentResult <-
                      pulumiSesBaseEnv repoRoot localPort accessKey secretKey
                    case baseEnvironmentResult of
                      Left err -> pure (Left err)
                      Right baseEnvironment -> do
                        loginExit <- pulumiLogin projectDir baseEnvironment
                        case loginExit of
                          ExitFailure _ -> pure (Left "pulumi login failed")
                          ExitSuccess -> do
                            selectExit <- pulumiStackSelect projectDir baseEnvironment True
                            case selectExit of
                              PulumiStackMissing ->
                                pure (Left "pulumi stack select reported a missing stack after --create")
                              PulumiStackSelectFailed detail ->
                                pure (Left ("pulumi stack select failed: " ++ detail))
                              PulumiStackSelected -> do
                                syncExit <-
                                  syncAwsSesStackConfig projectDir baseEnvironment stackConfig
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
                                                saveAwsSesStackSnapshot repoRoot snapshot
                                                objectCountResult <-
                                                  bucketObjectCount localPort accessKey secretKey
                                                case objectCountResult of
                                                  Left err -> pure (Left err)
                                                  Right objectCount -> do
                                                    writeOutput
                                                      (renderAwsSesStackReport snapshot objectCount)
                                                    pure (Right ())
          case portForwardResult of
            Left err -> failWith err
            Right (Left err) -> failWith err
            Right (Right ()) -> pure ExitSuccess

destroyAwsSesStack :: FilePath -> Bool -> IO ExitCode
destroyAwsSesStack repoRoot summary = do
  statusResult <- destroyAwsSesStackStatus repoRoot summary
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS SES stack: " ++ status)
      pure ExitSuccess

destroyAwsSesStackStatus :: FilePath -> Bool -> IO (Either String String)
destroyAwsSesStackStatus repoRoot summary = do
  currentSnapshot <- loadAwsSesStackSnapshot repoRoot
  let projectDir = awsSesPulumiProjectDir repoRoot
  portForwardResult <- withMinioPortForward $ \localPort -> do
    credsResult <- readMinioCredentials
    case credsResult of
      Left err -> pure (Left err)
      Right (accessKey, secretKey) -> do
        bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
        case bucketResult of
          Left err -> pure (Left err)
          Right () -> do
            backendEnvironment <- pulumiBackendBaseEnv localPort accessKey secretKey
            loginResult <- pulumiLoginEither projectDir backendEnvironment summary
            case loginResult of
              Left err -> pure (Left ("pulumi login failed: " ++ err))
              Right () -> do
                selectExit <- pulumiStackSelect projectDir backendEnvironment False
                case selectExit of
                  PulumiStackSelected -> do
                    operationalCredentialsResult <- loadOperationalAwsCredentials repoRoot
                    case operationalCredentialsResult of
                      Left err ->
                        pure
                          ( Left
                              ( "operational AWS credentials are required to destroy the AWS SES stack: "
                                  ++ err
                              )
                          )
                      Right operationalCredentials -> do
                        configResult <- resolveAwsSesStackConfig repoRoot
                        case configResult of
                          Left err -> pure (Left err)
                          Right stackConfig -> do
                            let providerEnvironment =
                                  backendEnvironment ++ pulumiAwsProviderEnv operationalCredentials
                            syncExit <-
                              syncAwsSesStackConfig projectDir providerEnvironment stackConfig
                            case syncExit of
                              ExitFailure _ -> pure (Left "pulumi config set failed")
                              ExitSuccess -> do
                                destroyResult <-
                                  pulumiDestroyEither projectDir providerEnvironment summary
                                case destroyResult of
                                  Left err -> pure (Left ("pulumi destroy failed: " ++ err))
                                  Right () -> completeDestroy repoRoot projectDir providerEnvironment summary
                  PulumiStackMissing ->
                    case currentSnapshot of
                      Nothing -> pure (Right "already absent from the local Pulumi backend")
                      Just _ -> finalizeDestroy repoRoot
                  PulumiStackSelectFailed detail ->
                    pure (Left ("pulumi stack select failed: " ++ detail))
  case portForwardResult of
    Left err ->
      case currentSnapshot of
        Nothing ->
          pure (Right "no local Pulumi backend or saved residue snapshot; nothing to destroy")
        Just _ ->
          pure
            ( Left
                ( "local MinIO backend unavailable while an AWS SES stack snapshot still exists: "
                    ++ err
                )
            )
    Right (Left err) -> pure (Left err)
    Right (Right status) -> pure (Right status)

completeDestroy
  :: FilePath -> FilePath -> [(String, String)] -> Bool -> IO (Either String String)
completeDestroy repoRoot projectDir environment summary = do
  _ <- pulumiStackRemoveEither projectDir environment False summary
  finalizeDestroy repoRoot

finalizeDestroy :: FilePath -> IO (Either String String)
finalizeDestroy repoRoot = do
  clearAwsSesStackSnapshot repoRoot
  pure (Right "destroyed and snapshot cleared")

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
assertNoAwsSesStackResidue
  :: FilePath -> Maybe AwsSesStackSnapshot -> IO (Either String ())
assertNoAwsSesStackResidue repoRoot maybeSnapshot = do
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
 where
  _ = maybeSnapshot

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
