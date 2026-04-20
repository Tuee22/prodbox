{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsEksTestStack
    ( AwsEksTestStackSnapshot (..),
      awsEksTestStackName,
      ensureAwsEksTestStackResources,
      destroyAwsEksTestStack,
      loadAwsEksTestStackSnapshot,
      saveAwsEksTestStackSnapshot,
      clearAwsEksTestStackSnapshot,
      assertNoAwsEksTestStackResidue,
      renderAwsEksTestStackReport,
    )
where

import Control.Monad (foldM, forM)
import Data.List (isInfixOf)
import Data.Char (toLower)
import Data.Aeson
    ( Value (..),
      eitherDecode,
      encode,
      object,
      (.=),
    )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Prodbox.Infra.MinioBackend
    ( bucketObjectCount,
      ensureMinioBackendBucket,
      pulumiBackendUrl,
      readMinioCredentials,
      withMinioPortForward,
    )
import Prodbox.Result (Result (..))
import Prodbox.Settings
    ( Credentials (..),
      ValidatedSettings (..),
      aws,
      validateAndLoadSettings,
    )
import Prodbox.Subprocess
    ( CommandSpec (..),
      ProcessOutput (..),
      captureCommand,
      runStreamingCommand,
    )
import System.Directory
    ( createDirectoryIfMissing,
      doesFileExist,
      removeFile,
    )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

awsEksTestStackName :: String
awsEksTestStackName = "aws-eks-test"

awsEksTestPulumiProjectDir :: FilePath -> FilePath
awsEksTestPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-eks"

awsEksTestStateDir :: FilePath -> FilePath
awsEksTestStateDir repoRoot = repoRoot </> ".prodbox-state" </> awsEksTestStackName

awsEksTestSnapshotPath :: FilePath -> FilePath
awsEksTestSnapshotPath repoRoot = awsEksTestStateDir repoRoot </> "stack-snapshot.json"

data AwsEksTestStackSnapshot = AwsEksTestStackSnapshot
    { eksSnapshotStackName :: String,
      eksSnapshotBackendBucket :: String,
      eksSnapshotClusterName :: String,
      eksSnapshotClusterRoleName :: String,
      eksSnapshotNodeGroupName :: String,
      eksSnapshotNodeRoleName :: String,
      eksSnapshotVpcId :: String,
      eksSnapshotSubnetIds :: [String],
      eksSnapshotClusterSecurityGroupId :: String
    }
    deriving (Eq, Show)

newtype AwsEksTestStackConfig = AwsEksTestStackConfig
    { eksStackOperatorCidr :: String
    }
    deriving (Eq, Show)

saveAwsEksTestStackSnapshot :: FilePath -> AwsEksTestStackSnapshot -> IO ()
saveAwsEksTestStackSnapshot repoRoot snapshot = do
    let stateDir = awsEksTestStateDir repoRoot
    createDirectoryIfMissing True stateDir
    BL.writeFile (awsEksTestSnapshotPath repoRoot) (encode (snapshotToJson snapshot))

loadAwsEksTestStackSnapshot :: FilePath -> IO (Maybe AwsEksTestStackSnapshot)
loadAwsEksTestStackSnapshot repoRoot = do
    let snapshotPath = awsEksTestSnapshotPath repoRoot
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

clearAwsEksTestStackSnapshot :: FilePath -> IO ()
clearAwsEksTestStackSnapshot repoRoot = do
    let snapshotPath = awsEksTestSnapshotPath repoRoot
    exists <- doesFileExist snapshotPath
    if exists then removeFile snapshotPath else pure ()

snapshotToJson :: AwsEksTestStackSnapshot -> Value
snapshotToJson snapshot =
    object
        [ "stack_name" .= eksSnapshotStackName snapshot,
          "backend_bucket" .= eksSnapshotBackendBucket snapshot,
          "cluster_name" .= eksSnapshotClusterName snapshot,
          "cluster_role_name" .= eksSnapshotClusterRoleName snapshot,
          "node_group_name" .= eksSnapshotNodeGroupName snapshot,
          "node_role_name" .= eksSnapshotNodeRoleName snapshot,
          "vpc_id" .= eksSnapshotVpcId snapshot,
          "subnet_ids" .= eksSnapshotSubnetIds snapshot,
          "cluster_security_group_id" .= eksSnapshotClusterSecurityGroupId snapshot
        ]

snapshotFromJson :: Value -> Either String AwsEksTestStackSnapshot
snapshotFromJson (Object obj) = do
    stackName <- requireString obj "stack_name"
    backendBucket <- requireString obj "backend_bucket"
    clusterName <- requireString obj "cluster_name"
    clusterRoleName <- requireString obj "cluster_role_name"
    nodeGroupName <- requireString obj "node_group_name"
    nodeRoleName <- requireString obj "node_role_name"
    vpcId <- requireString obj "vpc_id"
    subnetIds <- requireStringList obj "subnet_ids"
    clusterSecurityGroupId <- requireString obj "cluster_security_group_id"
    Right
        AwsEksTestStackSnapshot
            { eksSnapshotStackName = stackName,
              eksSnapshotBackendBucket = backendBucket,
              eksSnapshotClusterName = clusterName,
              eksSnapshotClusterRoleName = clusterRoleName,
              eksSnapshotNodeGroupName = nodeGroupName,
              eksSnapshotNodeRoleName = nodeRoleName,
              eksSnapshotVpcId = vpcId,
              eksSnapshotSubnetIds = subnetIds,
              eksSnapshotClusterSecurityGroupId = clusterSecurityGroupId
            }
snapshotFromJson _ = Left "snapshot must be a JSON object"

snapshotFromOutputs :: Value -> Either String AwsEksTestStackSnapshot
snapshotFromOutputs (Object obj) = do
    backendBucket <- requireString obj "backend_bucket"
    clusterName <- requireString obj "cluster_name"
    clusterRoleName <- requireString obj "cluster_role_name"
    nodeGroupName <- requireString obj "node_group_name"
    nodeRoleName <- requireString obj "node_role_name"
    vpcId <- requireString obj "vpc_id"
    subnetIds <- requireStringList obj "subnet_ids"
    clusterSecurityGroupId <- requireString obj "cluster_security_group_id"
    Right
        AwsEksTestStackSnapshot
            { eksSnapshotStackName = awsEksTestStackName,
              eksSnapshotBackendBucket = backendBucket,
              eksSnapshotClusterName = clusterName,
              eksSnapshotClusterRoleName = clusterRoleName,
              eksSnapshotNodeGroupName = nodeGroupName,
              eksSnapshotNodeRoleName = nodeRoleName,
              eksSnapshotVpcId = vpcId,
              eksSnapshotSubnetIds = subnetIds,
              eksSnapshotClusterSecurityGroupId = clusterSecurityGroupId
            }
snapshotFromOutputs _ = Left "pulumi output must be a JSON object"

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
        Just (Array arr) ->
            mapM
                ( \v -> case v of
                    String text ->
                        let str = Text.unpack text
                         in if null str then Left ("output " ++ key ++ " contains empty string") else Right str
                    _ -> Left ("output " ++ key ++ " must contain strings only")
                )
                (Vector.toList arr)
        _ -> Left ("missing list output " ++ key)

renderAwsEksTestStackReport :: AwsEksTestStackSnapshot -> Int -> String
renderAwsEksTestStackReport snapshot objectCount =
    unlines
        [ "STACK=" ++ eksSnapshotStackName snapshot,
          "BACKEND_BUCKET=" ++ eksSnapshotBackendBucket snapshot,
          "BACKEND_OBJECT_COUNT=" ++ show objectCount,
          "CLUSTER_NAME=" ++ eksSnapshotClusterName snapshot,
          "NODE_GROUP_NAME=" ++ eksSnapshotNodeGroupName snapshot,
          "CLUSTER_ROLE_NAME=" ++ eksSnapshotClusterRoleName snapshot,
          "NODE_ROLE_NAME=" ++ eksSnapshotNodeRoleName snapshot,
          "VPC_ID=" ++ eksSnapshotVpcId snapshot,
          "SUBNET_IDS=" ++ joinComma (eksSnapshotSubnetIds snapshot),
          "CLUSTER_SECURITY_GROUP_ID=" ++ eksSnapshotClusterSecurityGroupId snapshot
        ]

settingsAwsEnv :: FilePath -> IO (Either String [(String, String)])
settingsAwsEnv repoRoot = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
            baseEnv <- getEnvironment
            let creds = aws (validatedConfig settings)
                withKeys =
                    upsertEnv "AWS_ACCESS_KEY_ID" (Text.unpack (access_key_id creds))
                        $ upsertEnv "AWS_SECRET_ACCESS_KEY" (Text.unpack (secret_access_key creds))
                        $ upsertEnv "AWS_REGION" (Text.unpack (region creds))
                        $ upsertEnv "AWS_DEFAULT_REGION" (Text.unpack (region creds))
                        $ baseEnv
                withToken = case session_token creds of
                    Just token -> upsertEnv "AWS_SESSION_TOKEN" (Text.unpack token) withKeys
                    Nothing -> filter ((/= "AWS_SESSION_TOKEN") . fst) withKeys
            pure (Right withToken)

fetchPublicIpv4 :: IO (Either String String)
fetchPublicIpv4 = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "curl",
                  commandArguments = ["-s", "--max-time", "10", "https://api.ipify.org"],
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Nothing
                }
    case result of
        Failure err -> pure (Left ("failed to fetch public IP: " ++ err))
        Success output ->
            case processExitCode output of
                ExitSuccess ->
                    let ip = trim (processStdout output)
                     in if length (filter (== '.') ip) == 3
                            then pure (Right ip)
                            else pure (Left ("unexpected public IP response: " ++ ip))
                ExitFailure _ -> pure (Left ("curl failed: " ++ trim (processStderr output)))

pulumiEksBaseEnv :: Int -> String -> String -> IO [(String, String)]
pulumiEksBaseEnv localPort minioAccessKey minioSecretKey = do
    currentEnv <- getEnvironment
    let path = maybe "" id (lookup "PATH" currentEnv)
        home = maybe "" id (lookup "HOME" currentEnv)
    pure
        [ ("AWS_ACCESS_KEY_ID", minioAccessKey),
          ("AWS_SECRET_ACCESS_KEY", minioSecretKey),
          ("AWS_REGION", "us-east-1"),
          ("AWS_DEFAULT_REGION", "us-east-1"),
          ("AWS_EC2_METADATA_DISABLED", "true"),
          ("PULUMI_BACKEND_URL", pulumiBackendUrl localPort),
          ("PULUMI_CONFIG_PASSPHRASE", ""),
          ("PATH", path),
          ("HOME", home),
          ("LANG", "C.UTF-8")
        ]

resolveAwsEksTestStackConfig :: IO (Either String AwsEksTestStackConfig)
resolveAwsEksTestStackConfig = do
    publicIpResult <- fetchPublicIpv4
    case publicIpResult of
        Left err -> pure (Left err)
        Right publicIp ->
            pure
                ( Right
                    AwsEksTestStackConfig
                        { eksStackOperatorCidr = publicIp ++ "/32"
                        }
                )

syncAwsEksTestStackConfig :: FilePath -> [(String, String)] -> AwsEksTestStackConfig -> IO ExitCode
syncAwsEksTestStackConfig projectDir environment stackConfig =
    foldM runConfigSet ExitSuccess configEntries
  where
    configEntries = [(False, "operatorCidr", eksStackOperatorCidr stackConfig)]

    runConfigSet :: ExitCode -> (Bool, String, String) -> IO ExitCode
    runConfigSet failure@(ExitFailure _) _ = pure failure
    runConfigSet ExitSuccess (secretValue, key, value) =
        runPulumiCommand
            projectDir
            environment
            ( ["config", "set", "--stack", awsEksTestStackName]
                ++ ["--secret" | secretValue]
                ++ [key, value]
            )

syncAwsProviderConfig :: FilePath -> FilePath -> [(String, String)] -> IO ExitCode
syncAwsProviderConfig repoRoot projectDir environment = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left _ -> pure (ExitFailure 1)
        Right settings ->
            foldM runConfigSet ExitSuccess (providerConfigEntries (aws (validatedConfig settings)))
  where
    providerConfigEntries creds =
        [ (False, "aws:region", Text.unpack (region creds)),
          (True, "aws:accessKey", Text.unpack (access_key_id creds)),
          (True, "aws:secretKey", Text.unpack (secret_access_key creds)),
          (True, "aws:token", maybe "" Text.unpack (session_token creds)),
          (False, "awsRegion", Text.unpack (region creds)),
          (True, "awsAccessKeyId", Text.unpack (access_key_id creds)),
          (True, "awsSecretAccessKey", Text.unpack (secret_access_key creds)),
          (True, "awsSessionToken", maybe "" Text.unpack (session_token creds))
        ]

    runConfigSet :: ExitCode -> (Bool, String, String) -> IO ExitCode
    runConfigSet failure@(ExitFailure _) _ = pure failure
    runConfigSet ExitSuccess (secretValue, key, value) =
        runPulumiCommand
            projectDir
            environment
            ( ["config", "set", "--stack", awsEksTestStackName]
                ++ ["--secret" | secretValue]
                ++ [key, value]
            )

pulumiLogin :: FilePath -> [(String, String)] -> IO ExitCode
pulumiLogin projectDir environment =
    runPulumiCommand projectDir environment ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]

pulumiLoginQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiLoginQuiet projectDir environment =
    runPulumiCommandQuiet projectDir environment ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]

data PulumiStackSelectResult
    = PulumiStackSelected
    | PulumiStackMissing
    | PulumiStackSelectFailed String

pulumiStackSelect :: FilePath -> [(String, String)] -> Bool -> IO PulumiStackSelectResult
pulumiStackSelect projectDir environment createIfMissing =
    let arguments = ["stack", "select", awsEksTestStackName] ++ ["--create" | createIfMissing]
     in if createIfMissing
            then do
                exitCode <- runPulumiCommand projectDir environment arguments
                pure $
                    case exitCode of
                        ExitSuccess -> PulumiStackSelected
                        ExitFailure _ -> PulumiStackSelectFailed "pulumi stack select failed"
            else do
                result <-
                    captureCommand
                        CommandSpec
                            { commandPath = "pulumi",
                              commandArguments = arguments,
                              commandEnvironment = Just environment,
                              commandWorkingDirectory = Just projectDir
                            }
                pure $
                    case result of
                        Failure err -> PulumiStackSelectFailed err
                        Success output ->
                            case processExitCode output of
                                ExitSuccess -> PulumiStackSelected
                                ExitFailure _
                                    | isMissingPulumiStackError awsEksTestStackName (renderProcessDetail output) ->
                                        PulumiStackMissing
                                    | otherwise ->
                                        PulumiStackSelectFailed (renderProcessDetail output)

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
    runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsEksTestStackName]

pulumiDestroyQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiDestroyQuiet projectDir environment =
    runPulumiCommandQuiet projectDir environment ["destroy", "--yes", "--stack", awsEksTestStackName]

pulumiRefreshQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiRefreshQuiet projectDir environment =
    runPulumiCommandQuiet projectDir environment ["refresh", "--yes", "--stack", awsEksTestStackName]

pulumiStackRemoveQuiet :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiStackRemoveQuiet projectDir environment force =
    runPulumiCommandQuiet
        projectDir
        environment
        (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsEksTestStackName])

pulumiStackOutputs :: FilePath -> [(String, String)] -> IO (Either String Value)
pulumiStackOutputs projectDir environment = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = ["stack", "output", "--json", "--stack", awsEksTestStackName],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just projectDir
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
        runStreamingCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = arguments,
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just projectDir
                }
    case result of
        Failure err -> do
            hPutStrLn stderr err
            pure (ExitFailure 1)
        Success exitCode -> pure exitCode

runPulumiCommandQuiet :: FilePath -> [(String, String)] -> [String] -> IO (Either String ())
runPulumiCommandQuiet projectDir environment arguments = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = arguments,
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just projectDir
                }
    pure $
        case result of
            Failure err -> Left err
            Success output ->
                case processExitCode output of
                    ExitSuccess -> Right ()
                    ExitFailure _ -> Left (renderProcessDetail output)

resourceStillExists :: FilePath -> [String] -> IO (Either String Bool)
resourceStillExists repoRoot command = do
    envResult <- settingsAwsEnv repoRoot
    case envResult of
        Left err -> pure (Left err)
        Right environment -> do
            result <-
                captureCommand
                    CommandSpec
                        { commandPath = head command,
                          commandArguments = tail command,
                          commandEnvironment = Just environment,
                          commandWorkingDirectory = Nothing
                        }
            case result of
                Failure err -> pure (Left err)
                Success output ->
                    case processExitCode output of
                        ExitSuccess -> pure (Right True)
                        ExitFailure _ ->
                            let detail = trim (processStderr output) ++ " " ++ trim (processStdout output)
                             in if isResourceMissing detail
                                    then pure (Right False)
                                    else pure (Left (unwords command ++ " failed: " ++ detail))

isResourceMissing :: String -> Bool
isResourceMissing detail =
    let lowered = map toLowerAscii detail
     in any (`isSubstring` lowered)
            [ "notfound", "not found", "does not exist",
              "invalidgroup.notfound", "invalidsubnetid.notfound",
              "invalidvpcid.notfound", "nosuchentity"
            ]

isSubstring :: String -> String -> Bool
isSubstring needle haystack = any (startsWith needle) (allTails haystack)
  where
    startsWith [] _ = True
    startsWith _ [] = False
    startsWith (a : as) (b : bs) = a == b && startsWith as bs

allTails :: [a] -> [[a]]
allTails [] = [[]]
allTails s@(_ : rest) = s : allTails rest

toLowerAscii :: Char -> Char
toLowerAscii c
    | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
    | otherwise = c

assertNoAwsEksTestStackResidue :: FilePath -> Maybe AwsEksTestStackSnapshot -> IO (Either String ())
assertNoAwsEksTestStackResidue repoRoot maybeSnapshot = do
    snapshot <- case maybeSnapshot of
        Just s -> pure (Just s)
        Nothing -> loadAwsEksTestStackSnapshot repoRoot
    case snapshot of
        Nothing -> pure (Right ())
        Just current -> do
            remaining <- checkResidueItems repoRoot current
            case remaining of
                Left err -> pure (Left err)
                Right items ->
                    if null items
                        then pure (Right ())
                        else pure (Left ("AWS EKS test stack residue remains: " ++ joinComma items))

checkResidueItems :: FilePath -> AwsEksTestStackSnapshot -> IO (Either String [String])
checkResidueItems repoRoot snapshot = do
    clusterResult <- resourceStillExists repoRoot ["aws", "eks", "describe-cluster", "--name", eksSnapshotClusterName snapshot]
    nodeGroupResult <- resourceStillExists repoRoot
        ["aws", "eks", "describe-nodegroup", "--cluster-name", eksSnapshotClusterName snapshot, "--nodegroup-name", eksSnapshotNodeGroupName snapshot]
    clusterRoleResult <- resourceStillExists repoRoot ["aws", "iam", "get-role", "--role-name", eksSnapshotClusterRoleName snapshot]
    nodeRoleResult <- resourceStillExists repoRoot ["aws", "iam", "get-role", "--role-name", eksSnapshotNodeRoleName snapshot]
    vpcResult <- resourceStillExists repoRoot ["aws", "ec2", "describe-vpcs", "--vpc-ids", eksSnapshotVpcId snapshot]
    subnetResults <- forM (eksSnapshotSubnetIds snapshot) $ \subnetId ->
        resourceStillExists repoRoot ["aws", "ec2", "describe-subnets", "--subnet-ids", subnetId]
    sgResult <- resourceStillExists repoRoot ["aws", "ec2", "describe-security-groups", "--group-ids", eksSnapshotClusterSecurityGroupId snapshot]
    let allResults =
            [ ("cluster=" ++ eksSnapshotClusterName snapshot, clusterResult),
              ("node-group=" ++ eksSnapshotNodeGroupName snapshot, nodeGroupResult),
              ("cluster-role=" ++ eksSnapshotClusterRoleName snapshot, clusterRoleResult),
              ("node-role=" ++ eksSnapshotNodeRoleName snapshot, nodeRoleResult),
              ("vpc=" ++ eksSnapshotVpcId snapshot, vpcResult)
            ]
                ++ zipWith (\sid r -> ("subnet=" ++ sid, r)) (eksSnapshotSubnetIds snapshot) subnetResults
                ++ [("security-group=" ++ eksSnapshotClusterSecurityGroupId snapshot, sgResult)]
    case sequence (map snd allResults) of
        Left err -> pure (Left err)
        Right existsList ->
            pure (Right [label | (label, True) <- zip (map fst allResults) existsList])

ensureAwsEksTestStackResources :: FilePath -> IO ExitCode
ensureAwsEksTestStackResources repoRoot = do
    let projectDir = awsEksTestPulumiProjectDir repoRoot
    projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
    if not projectExists
        then failWith ("Pulumi AWS EKS test project missing: " ++ projectDir)
        else do
            portForwardResult <- withMinioPortForward $ \localPort -> do
                credsResult <- readMinioCredentials
                case credsResult of
                    Left err -> pure (Left err)
                    Right (accessKey, secretKey) -> do
                        bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
                        case bucketResult of
                            Left err -> pure (Left err)
                            Right () -> do
                                configResult <- resolveAwsEksTestStackConfig
                                case configResult of
                                    Left err -> pure (Left err)
                                    Right stackConfig -> do
                                        baseEnvironment <- pulumiEksBaseEnv localPort accessKey secretKey
                                        loginExit <- pulumiLogin projectDir baseEnvironment
                                        case loginExit of
                                            ExitFailure _ -> pure (Left "pulumi login failed")
                                            ExitSuccess -> do
                                                selectExit <- pulumiStackSelect projectDir baseEnvironment True
                                                case selectExit of
                                                    PulumiStackSelected -> do
                                                        providerSyncExit <- syncAwsProviderConfig repoRoot projectDir baseEnvironment
                                                        case providerSyncExit of
                                                            ExitFailure _ -> pure (Left "pulumi provider config set failed")
                                                            ExitSuccess -> do
                                                                syncExit <- syncAwsEksTestStackConfig projectDir baseEnvironment stackConfig
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
                                                                                                saveAwsEksTestStackSnapshot repoRoot snapshot
                                                                                                objectCountResult <- bucketObjectCount localPort accessKey secretKey
                                                                                                case objectCountResult of
                                                                                                    Left err -> pure (Left err)
                                                                                                    Right objectCount -> do
                                                                                                        putStr (renderAwsEksTestStackReport snapshot objectCount)
                                                                                                        pure (Right ())
                                                    PulumiStackMissing ->
                                                        pure (Left "pulumi stack select reported a missing stack after --create")
                                                    PulumiStackSelectFailed detail ->
                                                        pure (Left ("pulumi stack select failed: " ++ detail))
            case portForwardResult of
                Left err -> failWith err
                Right (Left err) -> failWith err
                Right (Right ()) -> pure ExitSuccess

destroyAwsEksTestStack :: FilePath -> IO ExitCode
destroyAwsEksTestStack repoRoot = do
    statusResult <- destroyAwsEksTestStackStatus repoRoot
    case statusResult of
        Left err -> failWith err
        Right status -> do
            putStrLn ("AWS EKS test stack: " ++ status)
            pure ExitSuccess

destroyAwsEksTestStackStatus :: FilePath -> IO (Either String String)
destroyAwsEksTestStackStatus repoRoot = do
    currentSnapshot <- loadAwsEksTestStackSnapshot repoRoot
    let projectDir = awsEksTestPulumiProjectDir repoRoot
    portForwardResult <- withMinioPortForward $ \localPort -> do
        credsResult <- readMinioCredentials
        case credsResult of
            Left err -> pure (Left err)
            Right (accessKey, secretKey) -> do
                bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
                case bucketResult of
                    Left err -> pure (Left err)
                    Right () -> do
                        baseEnvironment <- pulumiEksBaseEnv localPort accessKey secretKey
                        loginResult <- pulumiLoginQuiet projectDir baseEnvironment
                        case loginResult of
                            Left err -> pure (Left ("pulumi login failed: " ++ err))
                            Right () -> do
                                selectExit <- pulumiStackSelect projectDir baseEnvironment False
                                case selectExit of
                                    PulumiStackSelected -> do
                                        configResult <- resolveAwsEksTestStackConfig
                                        case configResult of
                                            Left err -> pure (Left err)
                                            Right stackConfig -> do
                                                providerSyncExit <- syncAwsProviderConfig repoRoot projectDir baseEnvironment
                                                case providerSyncExit of
                                                    ExitFailure _ -> pure (Left "pulumi provider config set failed")
                                                    ExitSuccess -> do
                                                        syncExit <- syncAwsEksTestStackConfig projectDir baseEnvironment stackConfig
                                                        case syncExit of
                                                            ExitFailure _ -> pure (Left "pulumi config set failed")
                                                            ExitSuccess -> do
                                                                destroyResult <- pulumiDestroyQuiet projectDir baseEnvironment
                                                                case destroyResult of
                                                                    Left _ -> do
                                                                        _ <- pulumiRefreshQuiet projectDir baseEnvironment
                                                                        retryResult <- pulumiDestroyQuiet projectDir baseEnvironment
                                                                        case retryResult of
                                                                            Left err -> pure (Left ("pulumi destroy failed after refresh: " ++ err))
                                                                            Right () -> completeDestroy repoRoot projectDir baseEnvironment currentSnapshot
                                                                    Right () ->
                                                                        completeDestroy repoRoot projectDir baseEnvironment currentSnapshot
                                    PulumiStackMissing -> do
                                        case currentSnapshot of
                                            Nothing ->
                                                pure (Right "already absent from the local Pulumi backend")
                                            Just _ -> finalizeDestroy repoRoot currentSnapshot
                                    PulumiStackSelectFailed detail ->
                                        pure (Left ("pulumi stack select failed: " ++ detail))
    case portForwardResult of
        Left err ->
            case currentSnapshot of
                Nothing ->
                    pure (Right "no local Pulumi backend or saved residue snapshot; nothing to destroy")
                Just _ -> pure (Left ("local MinIO backend unavailable while an AWS EKS test stack snapshot still exists: " ++ err))
        Right (Left err) -> pure (Left err)
        Right (Right status) -> pure (Right status)

completeDestroy :: FilePath -> FilePath -> [(String, String)] -> Maybe AwsEksTestStackSnapshot -> IO (Either String String)
completeDestroy repoRoot projectDir environment currentSnapshot = do
    _ <- pulumiStackRemoveQuiet projectDir environment False
    finalizeDestroy repoRoot currentSnapshot

finalizeDestroy :: FilePath -> Maybe AwsEksTestStackSnapshot -> IO (Either String String)
finalizeDestroy repoRoot currentSnapshot = do
    residueResult <- assertNoAwsEksTestStackResidue repoRoot currentSnapshot
    case residueResult of
        Left err -> pure (Left err)
        Right () -> do
            clearAwsEksTestStackSnapshot repoRoot
            pure (Right "destroyed and residue check passed")

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)

joinComma :: [String] -> String
joinComma [] = ""
joinComma items = foldr1 (\a b -> a ++ "," ++ b) items

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv key value environment = (key, value) : filter ((/= key) . fst) environment

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
    case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
        [] -> "subprocess exited without output"
        rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

isMissingPulumiStackError :: String -> String -> Bool
isMissingPulumiStackError stackName detail =
    let lowered = map toLower detail
        loweredStackName = map toLower stackName
     in "no stack named" `isInfixOf` lowered
            && loweredStackName `isInfixOf` lowered
            && "found" `isInfixOf` lowered
