{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsEksSubzoneStack
  ( AwsEksSubzoneStackSnapshot (..)
  , awsEksSubzoneStackName
  , ensureAwsEksSubzoneStackResources
  , destroyAwsEksSubzoneStack
  , awsEksSubzoneStackResidueStatus
  , assertNoAwsEksSubzoneStackResidue
  , renderAwsEksSubzoneStackReport
  , parseAwsEksSubzoneStackFromOutputs
  )
where

import Control.Monad (foldM)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
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
import Prodbox.Infra.StackOutputs qualified as StackOutputs
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( AwsSubstrateSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , aws_substrate
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import System.Directory
  ( doesFileExist
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

awsEksSubzoneStackName :: String
awsEksSubzoneStackName = "aws-eks-subzone"

awsEksSubzonePulumiProjectDir :: FilePath -> FilePath
awsEksSubzonePulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-eks-subzone"

-- | Sprint 4.16 typed residue status. Delegates to the live
-- @pulumi stack ls --json@ source-of-truth query through
-- 'Prodbox.Lifecycle.LiveResidue'; callers that need all three
-- per-run statuses should call 'queryPerRunResidueStatuses' directly
-- to share the MinIO port-forward bracket.
awsEksSubzoneStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsEksSubzoneStackResidueStatus repoRoot =
  LiveResidue.perRunAwsEksSubzone <$> LiveResidue.queryPerRunResidueStatuses repoRoot

data AwsEksSubzoneStackSnapshot = AwsEksSubzoneStackSnapshot
  { subzoneSnapshotStackName :: String
  , subzoneSnapshotBackendBucket :: String
  , subzoneSnapshotSubzoneId :: String
  , subzoneSnapshotSubzoneName :: String
  , subzoneSnapshotSubzoneNameServers :: [String]
  , subzoneSnapshotParentZoneId :: String
  , subzoneSnapshotParentNsRecordFqdn :: String
  }
  deriving (Eq, Show)

data AwsEksSubzoneStackConfig = AwsEksSubzoneStackConfig
  { subzoneStackParentZoneId :: String
  , subzoneStackSubzoneName :: String
  }
  deriving (Eq, Show)

-- | Sprint 4.18: live source-of-truth read of the @aws-eks-subzone@ stack's
-- snapshot from the in-cluster MinIO Pulumi backend. Returns 'Nothing' when
-- the stack is absent, the backend is unreachable, or the outputs cannot
-- be parsed — matching the @Maybe@ contract the destroy path previously
-- got from the file cache.
fetchAwsEksSubzoneStackSnapshotFromBackend
  :: FilePath -> IO (Maybe AwsEksSubzoneStackSnapshot)
fetchAwsEksSubzoneStackSnapshotFromBackend repoRoot = do
  outputsResult <-
    LiveResidue.fetchPerRunStackOutputs
      repoRoot
      (StackOutputs.StackName (Text.pack awsEksSubzoneStackName))
  pure $ case outputsResult of
    Left _ -> Nothing
    Right outputs -> either (const Nothing) Just (parseAwsEksSubzoneStackFromOutputs outputs)

-- | Sprint 4.18: decode an 'AwsEksSubzoneStackSnapshot' record directly
-- from the flat @Map Text Text@ returned by
-- 'Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs'. Replaces the
-- legacy @.prodbox-state\/aws-eks-subzone\/stack-snapshot.json@ file-IO
-- consumer on the destroy and residue paths. Complex outputs (e.g.
-- @subzone_name_servers@) arrive as JSON-encoded strings and are decoded
-- back to their structured form here.
parseAwsEksSubzoneStackFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String AwsEksSubzoneStackSnapshot
parseAwsEksSubzoneStackFromOutputs outputs = do
  backendBucket <- requireMapString outputs "backend_bucket"
  subzoneId <- requireMapString outputs "subzone_id"
  subzoneName <- requireMapString outputs "subzone_name"
  subzoneNameServers <- requireMapStringList outputs "subzone_name_servers"
  parentZoneId <- requireMapString outputs "parent_zone_id"
  parentNsRecordFqdn <- requireMapString outputs "parent_ns_record_fqdn"
  Right
    AwsEksSubzoneStackSnapshot
      { subzoneSnapshotStackName = awsEksSubzoneStackName
      , subzoneSnapshotBackendBucket = backendBucket
      , subzoneSnapshotSubzoneId = subzoneId
      , subzoneSnapshotSubzoneName = subzoneName
      , subzoneSnapshotSubzoneNameServers = subzoneNameServers
      , subzoneSnapshotParentZoneId = parentZoneId
      , subzoneSnapshotParentNsRecordFqdn = parentNsRecordFqdn
      }

requireMapString :: Map.Map Text.Text Text.Text -> String -> Either String String
requireMapString outputs key =
  case Map.lookup (Text.pack key) outputs of
    Nothing -> Left ("aws-eks-subzone Pulumi outputs missing required field '" ++ key ++ "'")
    Just text ->
      let str = Text.unpack text
       in if null str
            then Left ("aws-eks-subzone Pulumi outputs field '" ++ key ++ "' is empty")
            else Right str

requireMapStringList :: Map.Map Text.Text Text.Text -> String -> Either String [String]
requireMapStringList outputs key =
  case Map.lookup (Text.pack key) outputs of
    Nothing -> Left ("aws-eks-subzone Pulumi outputs missing required field '" ++ key ++ "'")
    Just text ->
      case eitherDecode (BL8.pack (Text.unpack text)) of
        Left err ->
          Left ("aws-eks-subzone Pulumi outputs field '" ++ key ++ "' is not a JSON list: " ++ err)
        Right (Array arr) -> mapM (requireStringListEntry key) (Vector.toList arr)
        Right _ -> Left ("aws-eks-subzone Pulumi outputs field '" ++ key ++ "' must be a JSON list")

snapshotFromOutputs :: Value -> Either String AwsEksSubzoneStackSnapshot
snapshotFromOutputs (Object obj) = do
  backendBucket <- requireString obj "backend_bucket"
  subzoneId <- requireString obj "subzone_id"
  subzoneName <- requireString obj "subzone_name"
  subzoneNameServers <- requireStringList obj "subzone_name_servers"
  parentZoneId <- requireString obj "parent_zone_id"
  parentNsRecordFqdn <- requireString obj "parent_ns_record_fqdn"
  Right
    AwsEksSubzoneStackSnapshot
      { subzoneSnapshotStackName = awsEksSubzoneStackName
      , subzoneSnapshotBackendBucket = backendBucket
      , subzoneSnapshotSubzoneId = subzoneId
      , subzoneSnapshotSubzoneName = subzoneName
      , subzoneSnapshotSubzoneNameServers = subzoneNameServers
      , subzoneSnapshotParentZoneId = parentZoneId
      , subzoneSnapshotParentNsRecordFqdn = parentNsRecordFqdn
      }
snapshotFromOutputs _ = Left "subzone pulumi output must be a JSON object"

requireString :: KeyMap.KeyMap Value -> String -> Either String String
requireString obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (String text) ->
      let str = Text.unpack text
       in if null str then Left ("missing string output " ++ key) else Right str
    _ -> Left ("missing string output " ++ key)

requireStringList :: KeyMap.KeyMap Value -> String -> Either String [String]
requireStringList obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (Array arr) -> mapM (requireStringListEntry key) (Vector.toList arr)
    _ -> Left ("missing list output " ++ key)

requireStringListEntry :: String -> Value -> Either String String
requireStringListEntry key value =
  case value of
    String text ->
      let str = Text.unpack text
       in if null str then Left ("output " ++ key ++ " contains empty string") else Right str
    _ -> Left ("output " ++ key ++ " must contain strings only")

renderAwsEksSubzoneStackReport :: AwsEksSubzoneStackSnapshot -> Int -> String
renderAwsEksSubzoneStackReport snapshot objectCount =
  unlines
    [ "STACK=" ++ subzoneSnapshotStackName snapshot
    , "BACKEND_BUCKET=" ++ subzoneSnapshotBackendBucket snapshot
    , "BACKEND_OBJECT_COUNT=" ++ show objectCount
    , "SUBZONE_ID=" ++ subzoneSnapshotSubzoneId snapshot
    , "SUBZONE_NAME=" ++ subzoneSnapshotSubzoneName snapshot
    , "SUBZONE_NAME_SERVERS=" ++ joinComma (subzoneSnapshotSubzoneNameServers snapshot)
    , "PARENT_ZONE_ID=" ++ subzoneSnapshotParentZoneId snapshot
    , "PARENT_NS_RECORD_FQDN=" ++ subzoneSnapshotParentNsRecordFqdn snapshot
    ]

resolveAwsEksSubzoneStackConfig :: FilePath -> IO (Either String AwsEksSubzoneStackConfig)
resolveAwsEksSubzoneStackConfig repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  pure $ case settingsResult of
    Left err -> Left err
    Right settings ->
      let parentZoneId = Text.unpack (Text.strip (zone_id (route53 (validatedConfig settings))))
          subzoneSection = aws_substrate (validatedConfig settings)
          subzoneName = Text.unpack (Text.strip (subzone_name subzoneSection))
       in if null parentZoneId
            then Left "route53.zone_id must be set before provisioning the AWS subzone stack"
            else
              if null subzoneName
                then
                  Left
                    "aws_substrate.subzone_name must be set before provisioning the AWS subzone stack"
                else
                  Right
                    AwsEksSubzoneStackConfig
                      { subzoneStackParentZoneId = parentZoneId
                      , subzoneStackSubzoneName = subzoneName
                      }

syncAwsEksSubzoneStackConfig
  :: FilePath -> [(String, String)] -> AwsEksSubzoneStackConfig -> IO ExitCode
syncAwsEksSubzoneStackConfig projectDir environment stackConfig =
  foldM runConfigSet ExitSuccess configEntries
 where
  configEntries =
    [ ("parentZoneId", subzoneStackParentZoneId stackConfig)
    , ("subzoneName", subzoneStackSubzoneName stackConfig)
    ]

  runConfigSet :: ExitCode -> (String, String) -> IO ExitCode
  runConfigSet failure@(ExitFailure _) _ = pure failure
  runConfigSet ExitSuccess (key, value) =
    runPulumiCommand
      projectDir
      environment
      ["config", "set", "--stack", awsEksSubzoneStackName, key, value]

-- Pulumi flow helpers parameterized to the subzone stack.

pulumiSubzoneBaseEnv :: FilePath -> Int -> String -> String -> IO (Either String [(String, String)])
pulumiSubzoneBaseEnv repoRoot localPort minioAccessKey minioSecretKey = do
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
  let arguments = ["stack", "select", awsEksSubzoneStackName] ++ ["--create" | createIfMissing]
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
                  | isMissingPulumiStackError awsEksSubzoneStackName (renderProcessDetail output) ->
                      PulumiStackMissing
                  | otherwise ->
                      PulumiStackSelectFailed (renderProcessDetail output)

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
  runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsEksSubzoneStackName]

pulumiDestroyQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiDestroyQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["destroy", "--yes", "--stack", awsEksSubzoneStackName]

pulumiStackRemoveQuiet :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiStackRemoveQuiet projectDir environment force =
  runPulumiCommandQuiet
    projectDir
    environment
    (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsEksSubzoneStackName])

pulumiStackOutputs :: FilePath -> [(String, String)] -> IO (Either String Value)
pulumiStackOutputs projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["stack", "output", "--json", "--stack", awsEksSubzoneStackName]
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

joinComma :: [String] -> String
joinComma [] = ""
joinComma items = foldr1 (\a b -> a ++ "," ++ b) items

ensureAwsEksSubzoneStackResources :: FilePath -> IO ExitCode
ensureAwsEksSubzoneStackResources repoRoot = do
  let projectDir = awsEksSubzonePulumiProjectDir repoRoot
  projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
  if not projectExists
    then failWith ("Pulumi AWS subzone project missing: " ++ projectDir)
    else do
      configResult <- resolveAwsEksSubzoneStackConfig repoRoot
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
                      pulumiSubzoneBaseEnv repoRoot localPort accessKey secretKey
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
                                  syncAwsEksSubzoneStackConfig projectDir baseEnvironment stackConfig
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
                                                objectCountResult <-
                                                  bucketObjectCount localPort accessKey secretKey
                                                case objectCountResult of
                                                  Left err -> pure (Left err)
                                                  Right objectCount -> do
                                                    writeOutput
                                                      (renderAwsEksSubzoneStackReport snapshot objectCount)
                                                    pure (Right ())
          case portForwardResult of
            Left err -> failWith err
            Right (Left err) -> failWith err
            Right (Right ()) -> pure ExitSuccess

destroyAwsEksSubzoneStack :: FilePath -> Bool -> IO ExitCode
destroyAwsEksSubzoneStack repoRoot summary = do
  statusResult <- destroyAwsEksSubzoneStackStatus repoRoot summary
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS EKS subzone stack: " ++ status)
      pure ExitSuccess

destroyAwsEksSubzoneStackStatus :: FilePath -> Bool -> IO (Either String String)
destroyAwsEksSubzoneStackStatus repoRoot summary = do
  currentSnapshot <- fetchAwsEksSubzoneStackSnapshotFromBackend repoRoot
  let projectDir = awsEksSubzonePulumiProjectDir repoRoot
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
                              ( "operational AWS credentials are required to destroy the AWS subzone stack: "
                                  ++ err
                              )
                          )
                      Right operationalCredentials -> do
                        configResult <- resolveAwsEksSubzoneStackConfig repoRoot
                        case configResult of
                          Left err -> pure (Left err)
                          Right stackConfig -> do
                            let providerEnvironment =
                                  backendEnvironment ++ pulumiAwsProviderEnv operationalCredentials
                            syncExit <-
                              syncAwsEksSubzoneStackConfig projectDir providerEnvironment stackConfig
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
                      Just _ -> finalizeDestroy
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
                ( "local MinIO backend unavailable while an AWS subzone stack snapshot still exists: "
                    ++ err
                )
            )
    Right (Left err) -> pure (Left err)
    Right (Right status) -> pure (Right status)

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
          ["destroy", "--yes", "--stack", awsEksSubzoneStackName]

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
              ++ [awsEksSubzoneStackName]
          )

exitToEither :: String -> ExitCode -> Either String ()
exitToEither _ ExitSuccess = Right ()
exitToEither label (ExitFailure code) = Left (label ++ " exited with code " ++ show code)

-- Residue assertion. After teardown there should be no Route 53 hosted zone matching the
-- subzone name on the supported AWS account; the parent zone's delegation record should
-- also be absent.
assertNoAwsEksSubzoneStackResidue :: FilePath -> IO (Either String ())
assertNoAwsEksSubzoneStackResidue repoRoot = do
  configResult <- resolveAwsEksSubzoneStackConfig repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right stackConfig -> do
      let subzoneFqdn = subzoneStackSubzoneName stackConfig
          parentZoneId = subzoneStackParentZoneId stackConfig
      hostedZoneResidue <- discoverHostedZoneResidue repoRoot subzoneFqdn
      case hostedZoneResidue of
        Left err -> pure (Left err)
        Right (Just zoneId) ->
          pure
            ( Left
                ( "Route 53 hosted zone "
                    ++ zoneId
                    ++ " for `"
                    ++ subzoneFqdn
                    ++ "` still exists after destroy; manual cleanup required"
                )
            )
        Right Nothing -> do
          parentResidue <- discoverParentNsResidue repoRoot parentZoneId subzoneFqdn
          case parentResidue of
            Left err -> pure (Left err)
            Right True ->
              pure
                ( Left
                    ( "NS delegation record for `"
                        ++ subzoneFqdn
                        ++ "` is still present in parent zone "
                        ++ parentZoneId
                        ++ "; manual cleanup required"
                    )
                )
            Right False -> pure (Right ())

discoverHostedZoneResidue :: FilePath -> String -> IO (Either String (Maybe String))
discoverHostedZoneResidue repoRoot subzoneFqdn = do
  envResult <- settingsAwsEnv repoRoot
  case envResult of
    Left err -> pure (Left err)
    Right environment -> do
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "route53"
                , "list-hosted-zones-by-name"
                , "--dns-name"
                , subzoneFqdn
                , "--max-items"
                , "1"
                , "--output"
                , "json"
                ]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Nothing
            }
      pure $ case result of
        Failure err ->
          Left ("failed to start aws route53 list-hosted-zones-by-name: " ++ err)
        Success output ->
          case processExitCode output of
            ExitFailure _ ->
              Left
                ( "aws route53 list-hosted-zones-by-name failed: "
                    ++ trim (processStderr output)
                )
            ExitSuccess ->
              case eitherDecode (BL8.pack (processStdout output)) of
                Left err ->
                  Left ("failed to parse aws route53 list-hosted-zones-by-name JSON: " ++ err)
                Right value -> parseFirstMatchingZone subzoneFqdn value

parseFirstMatchingZone :: String -> Value -> Either String (Maybe String)
parseFirstMatchingZone subzoneFqdn (Object obj) =
  case KeyMap.lookup (Key.fromString "HostedZones") obj of
    Just (Array zones) ->
      let matches =
            [ zoneIdFromArn
            | Object zone <- Vector.toList zones
            , Just (String name) <- [KeyMap.lookup (Key.fromString "Name") zone]
            , normalizeName (Text.unpack name) == normalizeName subzoneFqdn
            , Just (String idText) <- [KeyMap.lookup (Key.fromString "Id") zone]
            , let zoneIdFromArn = stripHostedZonePrefix (Text.unpack idText)
            ]
       in case matches of
            [] -> Right Nothing
            zoneId : _ -> Right (Just zoneId)
    _ -> Right Nothing
parseFirstMatchingZone _ _ = Left "aws route53 list-hosted-zones-by-name returned a non-object payload"

stripHostedZonePrefix :: String -> String
stripHostedZonePrefix raw =
  let prefix = "/hostedzone/"
   in if prefix `isInfixOf` raw
        then drop (length prefix) raw
        else raw

normalizeName :: String -> String
normalizeName name =
  let lowered = map toLower name
   in if not (null lowered) && last lowered == '.'
        then init lowered
        else lowered

discoverParentNsResidue :: FilePath -> String -> String -> IO (Either String Bool)
discoverParentNsResidue repoRoot parentZoneId subzoneFqdn = do
  envResult <- settingsAwsEnv repoRoot
  case envResult of
    Left err -> pure (Left err)
    Right environment -> do
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "route53"
                , "list-resource-record-sets"
                , "--hosted-zone-id"
                , parentZoneId
                , "--start-record-name"
                , subzoneFqdn
                , "--start-record-type"
                , "NS"
                , "--max-items"
                , "1"
                , "--output"
                , "json"
                ]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Nothing
            }
      pure $ case result of
        Failure err ->
          Left ("failed to start aws route53 list-resource-record-sets: " ++ err)
        Success output ->
          case processExitCode output of
            ExitFailure _ ->
              Left
                ( "aws route53 list-resource-record-sets failed: "
                    ++ trim (processStderr output)
                )
            ExitSuccess ->
              case eitherDecode (BL8.pack (processStdout output)) of
                Left err ->
                  Left ("failed to parse aws route53 list-resource-record-sets JSON: " ++ err)
                Right value -> parseNsRecordPresence subzoneFqdn value

parseNsRecordPresence :: String -> Value -> Either String Bool
parseNsRecordPresence subzoneFqdn (Object obj) =
  case KeyMap.lookup (Key.fromString "ResourceRecordSets") obj of
    Just (Array records) ->
      let matches =
            [ True
            | Object record <- Vector.toList records
            , Just (String name) <- [KeyMap.lookup (Key.fromString "Name") record]
            , normalizeName (Text.unpack name) == normalizeName subzoneFqdn
            , Just (String recordType) <- [KeyMap.lookup (Key.fromString "Type") record]
            , Text.unpack recordType == "NS"
            ]
       in Right (not (null matches))
    _ -> Right False
parseNsRecordPresence _ _ = Left "aws route53 list-resource-record-sets returned a non-object payload"

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
