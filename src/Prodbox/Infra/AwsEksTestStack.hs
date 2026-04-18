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

import Control.Monad (forM)
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

pulumiEksEnv :: Int -> String -> String -> IO (Either String [(String, String)])
pulumiEksEnv localPort minioAccessKey minioSecretKey = do
    publicIpResult <- fetchPublicIpv4
    case publicIpResult of
        Left err -> pure (Left err)
        Right publicIp -> do
            currentEnv <- getEnvironment
            let path = maybe "" id (lookup "PATH" currentEnv)
                home = maybe "" id (lookup "HOME" currentEnv)
            pure
                ( Right
                    [ ("AWS_ACCESS_KEY_ID", minioAccessKey),
                      ("AWS_SECRET_ACCESS_KEY", minioSecretKey),
                      ("AWS_REGION", "us-east-1"),
                      ("AWS_DEFAULT_REGION", "us-east-1"),
                      ("AWS_EC2_METADATA_DISABLED", "true"),
                      ("PULUMI_BACKEND_URL", pulumiBackendUrl localPort),
                      ("PULUMI_CONFIG_PASSPHRASE", ""),
                      ("PRODBOX_AWS_EKS_TEST_OPERATOR_CIDR", publicIp ++ "/32"),
                      ("PATH", path),
                      ("HOME", home),
                      ("LANG", "C.UTF-8")
                    ]
                )

pulumiLogin :: FilePath -> [(String, String)] -> IO ExitCode
pulumiLogin projectDir environment =
    runPulumiCommand projectDir environment ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]

pulumiStackSelect :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
pulumiStackSelect projectDir environment createIfMissing =
    runPulumiCommand
        projectDir
        environment
        (["stack", "select", awsEksTestStackName] ++ ["--create" | createIfMissing])

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
    runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsEksTestStackName]

pulumiDestroy :: FilePath -> [(String, String)] -> IO ExitCode
pulumiDestroy projectDir environment =
    runPulumiCommand projectDir environment ["destroy", "--yes", "--stack", awsEksTestStackName]

pulumiRefresh :: FilePath -> [(String, String)] -> IO ExitCode
pulumiRefresh projectDir environment =
    runPulumiCommand projectDir environment ["refresh", "--yes", "--stack", awsEksTestStackName]

pulumiCancel :: FilePath -> [(String, String)] -> IO ExitCode
pulumiCancel projectDir environment =
    runPulumiCommand projectDir environment ["cancel", "--yes", "--stack", awsEksTestStackName]

pulumiStackRemove :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
pulumiStackRemove projectDir environment force =
    runPulumiCommand
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
              "invalidvpcid.notfound"
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
                                envResult <- pulumiEksEnv localPort accessKey secretKey
                                case envResult of
                                    Left err -> pure (Left err)
                                    Right environment -> do
                                        loginExit <- pulumiLogin projectDir environment
                                        case loginExit of
                                            ExitFailure _ -> pure (Left "pulumi login failed")
                                            ExitSuccess -> do
                                                selectExit <- pulumiStackSelect projectDir environment True
                                                case selectExit of
                                                    ExitFailure _ -> pure (Left "pulumi stack select failed")
                                                    ExitSuccess -> do
                                                        upExit <- pulumiUp projectDir environment
                                                        case upExit of
                                                            ExitFailure _ -> pure (Left "pulumi up failed")
                                                            ExitSuccess -> do
                                                                outputsResult <- pulumiStackOutputs projectDir environment
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
            case portForwardResult of
                Left err -> failWith err
                Right (Left err) -> failWith err
                Right (Right ()) -> pure ExitSuccess

destroyAwsEksTestStack :: FilePath -> IO ExitCode
destroyAwsEksTestStack repoRoot = do
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
                        envResult <- pulumiEksEnv localPort accessKey secretKey
                        case envResult of
                            Left err -> pure (Left err)
                            Right environment -> do
                                loginExit <- pulumiLogin projectDir environment
                                case loginExit of
                                    ExitFailure _ -> pure (Left "pulumi login failed")
                                    ExitSuccess -> do
                                        selectExit <- pulumiStackSelect projectDir environment False
                                        case selectExit of
                                            ExitFailure _ -> pure (Right "no stack to destroy")
                                            ExitSuccess -> do
                                                destroyExit <- pulumiDestroy projectDir environment
                                                case destroyExit of
                                                    ExitFailure _ -> do
                                                        _ <- pulumiRefresh projectDir environment
                                                        retryExit <- pulumiDestroy projectDir environment
                                                        case retryExit of
                                                            ExitFailure _ -> pure (Left "pulumi destroy failed after refresh")
                                                            ExitSuccess -> completeDestroy repoRoot projectDir environment currentSnapshot
                                                    ExitSuccess ->
                                                        completeDestroy repoRoot projectDir environment currentSnapshot
    case portForwardResult of
        Left err ->
            case currentSnapshot of
                Nothing -> do
                    putStrLn "Skipped AWS EKS test stack destroy because the local MinIO backend is not present and no saved AWS residue snapshot exists"
                    pure ExitSuccess
                Just _ -> failWith ("local MinIO backend unavailable while an AWS EKS test stack snapshot still exists: " ++ err)
        Right (Left err) -> failWith err
        Right (Right _) -> pure ExitSuccess

completeDestroy :: FilePath -> FilePath -> [(String, String)] -> Maybe AwsEksTestStackSnapshot -> IO (Either String String)
completeDestroy repoRoot projectDir environment currentSnapshot = do
    _ <- pulumiStackRemove projectDir environment False
    residueResult <- assertNoAwsEksTestStackResidue repoRoot currentSnapshot
    case residueResult of
        Left err -> pure (Left err)
        Right () -> do
            clearAwsEksTestStackSnapshot repoRoot
            putStrLn ("Destroyed stack " ++ awsEksTestStackName ++ "; verified no AWS residue")
            pure (Right "destroyed")

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
