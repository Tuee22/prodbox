{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsTestStack
    ( AwsTestNode (..),
      AwsTestStackSnapshot (..),
      awsTestStackName,
      ensureAwsTestStackResources,
      destroyAwsTestStack,
      loadAwsTestStackSnapshot,
      saveAwsTestStackSnapshot,
      clearAwsTestStackSnapshot,
      assertNoAwsTestStackResidue,
      renderAwsTestStackReport,
      ensureAwsTestSshKey,
    )
where

import Control.Monad (forM, void)
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

awsTestStackName :: String
awsTestStackName = "aws-test"

awsTestPulumiProjectDir :: FilePath -> FilePath
awsTestPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-test"

awsTestStateDir :: FilePath -> FilePath
awsTestStateDir repoRoot = repoRoot </> ".prodbox-state" </> awsTestStackName

awsTestSnapshotPath :: FilePath -> FilePath
awsTestSnapshotPath repoRoot = awsTestStateDir repoRoot </> "stack-snapshot.json"

awsTestPrivateKeyPath :: FilePath -> FilePath
awsTestPrivateKeyPath repoRoot = awsTestStateDir repoRoot </> "id_ed25519"

awsTestPublicKeyPath :: FilePath -> FilePath
awsTestPublicKeyPath repoRoot = awsTestStateDir repoRoot </> "id_ed25519.pub"

data AwsTestNode = AwsTestNode
    { testNodeName :: String,
      testNodeAvailabilityZone :: String,
      testNodeInstanceId :: String,
      testNodePrivateIp :: String,
      testNodePublicIp :: String
    }
    deriving (Eq, Show)

data AwsTestStackSnapshot = AwsTestStackSnapshot
    { testSnapshotStackName :: String,
      testSnapshotBackendBucket :: String,
      testSnapshotVpcId :: String,
      testSnapshotSubnetIds :: [String],
      testSnapshotSecurityGroupId :: String,
      testSnapshotNodes :: [AwsTestNode]
    }
    deriving (Eq, Show)

ensureAwsTestSshKey :: FilePath -> IO (Either String FilePath)
ensureAwsTestSshKey repoRoot = do
    let stateDir = awsTestStateDir repoRoot
        privateKeyPath = awsTestPrivateKeyPath repoRoot
        publicKeyPath = awsTestPublicKeyPath repoRoot
    createDirectoryIfMissing True stateDir
    privateExists <- doesFileExist privateKeyPath
    publicExists <- doesFileExist publicKeyPath
    if privateExists && publicExists
        then pure (Right privateKeyPath)
        else do
            result <-
                captureCommand
                    CommandSpec
                        { commandPath = "ssh-keygen",
                          commandArguments = ["-q", "-t", "ed25519", "-N", "", "-f", privateKeyPath],
                          commandEnvironment = Nothing,
                          commandWorkingDirectory = Nothing
                        }
            case result of
                Failure err -> pure (Left ("ssh-keygen failed: " ++ err))
                Success output ->
                    case processExitCode output of
                        ExitSuccess -> pure (Right privateKeyPath)
                        ExitFailure _ -> pure (Left ("ssh-keygen failed: " ++ trim (processStderr output)))

saveAwsTestStackSnapshot :: FilePath -> AwsTestStackSnapshot -> IO ()
saveAwsTestStackSnapshot repoRoot snapshot = do
    let stateDir = awsTestStateDir repoRoot
    createDirectoryIfMissing True stateDir
    BL.writeFile (awsTestSnapshotPath repoRoot) (encode (snapshotToJson snapshot))

loadAwsTestStackSnapshot :: FilePath -> IO (Maybe AwsTestStackSnapshot)
loadAwsTestStackSnapshot repoRoot = do
    let snapshotPath = awsTestSnapshotPath repoRoot
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

clearAwsTestStackSnapshot :: FilePath -> IO ()
clearAwsTestStackSnapshot repoRoot = do
    let snapshotPath = awsTestSnapshotPath repoRoot
    exists <- doesFileExist snapshotPath
    if exists then removeFile snapshotPath else pure ()

snapshotToJson :: AwsTestStackSnapshot -> Value
snapshotToJson snapshot =
    object
        [ "stack_name" .= testSnapshotStackName snapshot,
          "backend_bucket" .= testSnapshotBackendBucket snapshot,
          "vpc_id" .= testSnapshotVpcId snapshot,
          "subnet_ids" .= testSnapshotSubnetIds snapshot,
          "security_group_id" .= testSnapshotSecurityGroupId snapshot,
          "nodes" .= map nodeToJson (testSnapshotNodes snapshot)
        ]

nodeToJson :: AwsTestNode -> Value
nodeToJson node =
    object
        [ "name" .= testNodeName node,
          "availability_zone" .= testNodeAvailabilityZone node,
          "instance_id" .= testNodeInstanceId node,
          "private_ip" .= testNodePrivateIp node,
          "public_ip" .= testNodePublicIp node
        ]

snapshotFromJson :: Value -> Either String AwsTestStackSnapshot
snapshotFromJson (Object obj) = do
    stackName <- requireString obj "stack_name"
    backendBucket <- requireString obj "backend_bucket"
    vpcId <- requireString obj "vpc_id"
    subnetIds <- requireStringList obj "subnet_ids"
    securityGroupId <- requireString obj "security_group_id"
    nodes <- requireNodeList obj "nodes"
    Right
        AwsTestStackSnapshot
            { testSnapshotStackName = stackName,
              testSnapshotBackendBucket = backendBucket,
              testSnapshotVpcId = vpcId,
              testSnapshotSubnetIds = subnetIds,
              testSnapshotSecurityGroupId = securityGroupId,
              testSnapshotNodes = nodes
            }
snapshotFromJson _ = Left "snapshot must be a JSON object"

nodeFromJson :: Value -> Either String AwsTestNode
nodeFromJson (Object obj) = do
    name <- requireString obj "name"
    az <- requireString obj "availability_zone"
    instanceId <- requireString obj "instance_id"
    privateIp <- requireString obj "private_ip"
    publicIp <- requireString obj "public_ip"
    Right
        AwsTestNode
            { testNodeName = name,
              testNodeAvailabilityZone = az,
              testNodeInstanceId = instanceId,
              testNodePrivateIp = privateIp,
              testNodePublicIp = publicIp
            }
nodeFromJson _ = Left "node must be a JSON object"

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

requireNodeList :: KeyMap.KeyMap Value -> String -> Either String [AwsTestNode]
requireNodeList obj key =
    case KeyMap.lookup (Key.fromString key) obj of
        Just (Array arr) -> mapM nodeFromJson (Vector.toList arr)
        _ -> Left ("missing node list " ++ key)

renderAwsTestStackReport :: AwsTestStackSnapshot -> Int -> String
renderAwsTestStackReport snapshot objectCount =
    unlines
        ( [ "STACK=" ++ testSnapshotStackName snapshot,
            "BACKEND_BUCKET=" ++ testSnapshotBackendBucket snapshot,
            "BACKEND_OBJECT_COUNT=" ++ show objectCount,
            "VPC_ID=" ++ testSnapshotVpcId snapshot,
            "SUBNET_IDS=" ++ joinComma (testSnapshotSubnetIds snapshot),
            "SECURITY_GROUP_ID=" ++ testSnapshotSecurityGroupId snapshot,
            "NODE_COUNT=" ++ show (length (testSnapshotNodes snapshot))
          ]
            ++ concatMap renderNodeReport (zip [0 ..] (testSnapshotNodes snapshot))
        )

renderNodeReport :: (Int, AwsTestNode) -> [String]
renderNodeReport (index, node) =
    [ "NODE_" ++ show index ++ "_NAME=" ++ testNodeName node,
      "NODE_" ++ show index ++ "_AZ=" ++ testNodeAvailabilityZone node,
      "NODE_" ++ show index ++ "_INSTANCE_ID=" ++ testNodeInstanceId node,
      "NODE_" ++ show index ++ "_PRIVATE_IP=" ++ testNodePrivateIp node,
      "NODE_" ++ show index ++ "_PUBLIC_IP=" ++ testNodePublicIp node
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

pulumiTestEnv ::
    FilePath -> Int -> String -> String -> IO (Either String [(String, String)])
pulumiTestEnv repoRoot localPort minioAccessKey minioSecretKey = do
    publicKeyResult <- readSshPublicKey repoRoot
    publicIpResult <- fetchPublicIpv4
    case (publicKeyResult, publicIpResult) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right publicKey, Right publicIp) -> do
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
                      ("PRODBOX_AWS_TEST_PUBLIC_KEY", publicKey),
                      ("PRODBOX_AWS_TEST_OPERATOR_CIDR", publicIp ++ "/32"),
                      ("PATH", path),
                      ("HOME", home),
                      ("LANG", "C.UTF-8")
                    ]
                )

readSshPublicKey :: FilePath -> IO (Either String String)
readSshPublicKey repoRoot = do
    keyResult <- ensureAwsTestSshKey repoRoot
    case keyResult of
        Left err -> pure (Left err)
        Right _ -> do
            let publicKeyPath = awsTestPublicKeyPath repoRoot
            contents <- readFile publicKeyPath
            pure (Right (trim contents))

pulumiLogin :: FilePath -> [(String, String)] -> IO ExitCode
pulumiLogin projectDir environment =
    runPulumiCommand projectDir environment ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]

pulumiStackSelect :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
pulumiStackSelect projectDir environment createIfMissing =
    runPulumiCommand
        projectDir
        environment
        (["stack", "select", awsTestStackName] ++ ["--create" | createIfMissing])

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
    runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsTestStackName]

pulumiDestroy :: FilePath -> [(String, String)] -> IO ExitCode
pulumiDestroy projectDir environment =
    runPulumiCommand projectDir environment ["destroy", "--yes", "--stack", awsTestStackName]

pulumiStackRemove :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
pulumiStackRemove projectDir environment force =
    runPulumiCommand
        projectDir
        environment
        (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsTestStackName])

pulumiStackOutputs :: FilePath -> [(String, String)] -> IO (Either String Value)
pulumiStackOutputs projectDir environment = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = ["stack", "output", "--json", "--stack", awsTestStackName],
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

snapshotFromOutputs :: Value -> Either String AwsTestStackSnapshot
snapshotFromOutputs (Object obj) = do
    stackName <- Right awsTestStackName
    backendBucket <- requireString obj "backend_bucket"
    vpcId <- requireString obj "vpc_id"
    subnetIds <- requireStringList obj "subnet_ids"
    securityGroupId <- requireString obj "security_group_id"
    nodes <- requireNodeList obj "nodes"
    if length nodes /= 3
        then Left ("expected exactly 3 Pulumi-managed nodes, found " ++ show (length nodes))
        else
            Right
                AwsTestStackSnapshot
                    { testSnapshotStackName = stackName,
                      testSnapshotBackendBucket = backendBucket,
                      testSnapshotVpcId = vpcId,
                      testSnapshotSubnetIds = subnetIds,
                      testSnapshotSecurityGroupId = securityGroupId,
                      testSnapshotNodes = nodes
                    }
snapshotFromOutputs _ = Left "pulumi output must be a JSON object"

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
              "invalidvpcid.notfound", "invalidinstanceid.notfound",
              "nokeypair", "nosuchentity"
            ]

isSubstring :: String -> String -> Bool
isSubstring needle haystack = any (startsWith needle) (tails haystack)
  where
    startsWith [] _ = True
    startsWith _ [] = False
    startsWith (a : as) (b : bs) = a == b && startsWith as bs
    tails [] = [[]]
    tails s@(_ : rest) = s : tails rest

toLowerAscii :: Char -> Char
toLowerAscii c
    | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
    | otherwise = c

assertNoAwsTestStackResidue :: FilePath -> Maybe AwsTestStackSnapshot -> IO (Either String ())
assertNoAwsTestStackResidue repoRoot maybeSnapshot = do
    snapshot <- case maybeSnapshot of
        Just s -> pure (Just s)
        Nothing -> loadAwsTestStackSnapshot repoRoot
    case snapshot of
        Nothing -> pure (Right ())
        Just current -> do
            remainingItems <- checkResidueItems repoRoot current
            case remainingItems of
                Left err -> pure (Left err)
                Right remaining ->
                    if null remaining
                        then pure (Right ())
                        else pure (Left ("AWS test stack residue remains: " ++ joinComma remaining))

checkResidueItems :: FilePath -> AwsTestStackSnapshot -> IO (Either String [String])
checkResidueItems repoRoot snapshot = do
    vpcResult <- resourceStillExists repoRoot ["aws", "ec2", "describe-vpcs", "--vpc-ids", testSnapshotVpcId snapshot]
    case vpcResult of
        Left err -> pure (Left err)
        Right _vpcExists -> do
            subnetResults <- forM (testSnapshotSubnetIds snapshot) $ \subnetId ->
                resourceStillExists repoRoot ["aws", "ec2", "describe-subnets", "--subnet-ids", subnetId]
            sgResult <- resourceStillExists repoRoot ["aws", "ec2", "describe-security-groups", "--group-ids", testSnapshotSecurityGroupId snapshot]
            instanceResults <- forM (testSnapshotNodes snapshot) $ \node ->
                resourceStillExists repoRoot ["aws", "ec2", "describe-instances", "--instance-ids", testNodeInstanceId node]
            let allResults = [("vpc=" ++ testSnapshotVpcId snapshot, vpcResult)]
                    ++ zipWith (\sid r -> ("subnet=" ++ sid, r)) (testSnapshotSubnetIds snapshot) subnetResults
                    ++ [("security-group=" ++ testSnapshotSecurityGroupId snapshot, sgResult)]
                    ++ zipWith (\n r -> ("instance=" ++ testNodeInstanceId n, r)) (testSnapshotNodes snapshot) instanceResults
            case sequence (map snd allResults) of
                Left err -> pure (Left err)
                Right existsList ->
                    pure (Right [label | (label, True) <- zip (map fst allResults) existsList])

ensureAwsTestStackResources :: FilePath -> IO ExitCode
ensureAwsTestStackResources repoRoot = do
    let projectDir = awsTestPulumiProjectDir repoRoot
    projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
    if not projectExists
        then failWith ("Pulumi AWS test project missing: " ++ projectDir)
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
                                envResult <- pulumiTestEnv repoRoot localPort accessKey secretKey
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
                                                                                saveAwsTestStackSnapshot repoRoot snapshot
                                                                                objectCountResult <- bucketObjectCount localPort accessKey secretKey
                                                                                case objectCountResult of
                                                                                    Left err -> pure (Left err)
                                                                                    Right objectCount -> do
                                                                                        putStr (renderAwsTestStackReport snapshot objectCount)
                                                                                        pure (Right ())
            case portForwardResult of
                Left err -> failWith err
                Right (Left err) -> failWith err
                Right (Right ()) -> pure ExitSuccess

destroyAwsTestStack :: FilePath -> IO ExitCode
destroyAwsTestStack repoRoot = do
    currentSnapshot <- loadAwsTestStackSnapshot repoRoot
    let projectDir = awsTestPulumiProjectDir repoRoot
    portForwardResult <- withMinioPortForward $ \localPort -> do
        credsResult <- readMinioCredentials
        case credsResult of
            Left err -> pure (Left err)
            Right (accessKey, secretKey) -> do
                bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
                case bucketResult of
                    Left err -> pure (Left err)
                    Right () -> do
                        envResult <- pulumiTestEnv repoRoot localPort accessKey secretKey
                        case envResult of
                            Left err -> pure (Left err)
                            Right environment -> do
                                loginExit <- pulumiLogin projectDir environment
                                case loginExit of
                                    ExitFailure _ -> pure (Left "pulumi login failed")
                                    ExitSuccess -> do
                                        selectExit <- pulumiStackSelect projectDir environment False
                                        case selectExit of
                                            ExitFailure _ ->
                                                pure (Right ("no stack to destroy" :: String))
                                            ExitSuccess -> do
                                                destroyExit <- pulumiDestroy projectDir environment
                                                case destroyExit of
                                                    ExitFailure _ -> pure (Left "pulumi destroy failed")
                                                    ExitSuccess -> do
                                                        void (pulumiStackRemove projectDir environment False)
                                                        residueResult <- assertNoAwsTestStackResidue repoRoot currentSnapshot
                                                        case residueResult of
                                                            Left err -> pure (Left err)
                                                            Right () -> do
                                                                clearAwsTestStackSnapshot repoRoot
                                                                putStrLn ("Destroyed stack " ++ awsTestStackName ++ "; verified no AWS residue")
                                                                pure (Right ("destroyed" :: String))
    case portForwardResult of
        Left err ->
            case currentSnapshot of
                Nothing -> do
                    putStrLn "Skipped AWS test stack destroy because the local MinIO backend is not present and no saved AWS residue snapshot exists"
                    pure ExitSuccess
                Just _ -> failWith ("local MinIO backend unavailable while an AWS test stack snapshot still exists: " ++ err)
        Right (Left err) -> failWith err
        Right (Right _) -> pure ExitSuccess

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
