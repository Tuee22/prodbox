{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.MinioBackend (
    minioBackendBucket,
    minioBackendLocalPort,
    minioBackendRegion,
    pulumiBackendLoginTimeoutSeconds,
    minioNamespace,
    minioSecretName,
    minioServiceName,
    withMinioPortForward,
    readMinioCredentials,
    ensureMinioBackendBucket,
    bucketObjectCount,
    pulumiBackendUrl,
    minioEndpointUrl,
    resolveLocalKubeconfig,
    minioAwsEnv,
    parseDeletedMinioExportHostPath,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (
    IOException,
    bracket,
    try,
 )
import Data.Aeson (
    Value (..),
    eitherDecode,
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isSuffixOf)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
 )
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.Process (
    CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
 )

minioBackendBucket :: String
minioBackendBucket = "prodbox-test-pulumi-backends"

minioBackendLocalPort :: Int
minioBackendLocalPort = 39000

minioBackendRegion :: String
minioBackendRegion = "us-east-1"

pulumiBackendLoginTimeoutSeconds :: Int
pulumiBackendLoginTimeoutSeconds = 30

minioRolloutTimeoutSeconds :: Int
minioRolloutTimeoutSeconds = 120

minioNamespace :: String
minioNamespace = "prodbox"

minioDeploymentName :: String
minioDeploymentName = "minio"

minioSecretName :: String
minioSecretName = "minio"

minioServiceName :: String
minioServiceName = "minio"

minioExportMountPath :: String
minioExportMountPath = "/export"

deletedMountSuffix :: String
deletedMountSuffix = "//deleted"

minioEndpointUrl :: Int -> String
minioEndpointUrl localPort = "http://127.0.0.1:" ++ show localPort

pulumiBackendUrl :: Int -> String
pulumiBackendUrl localPort =
    "s3://"
        ++ minioBackendBucket
        ++ "?region="
        ++ minioBackendRegion
        ++ "&endpoint=127.0.0.1:"
        ++ show localPort
        ++ "&disableSSL=true"
        ++ "&s3ForcePathStyle=true"

resolveLocalKubeconfig :: IO (Either String FilePath)
resolveLocalKubeconfig = do
    kubeconfigEnv <- lookupEnv "KUBECONFIG"
    homeDir <- lookupEnv "HOME"
    let candidates =
            [ path
            | Just path <-
                [ kubeconfigEnv
                , fmap (</> ".kube" </> "config") homeDir
                , Just "/etc/rancher/rke2/rke2.yaml"
                ]
            ]
    findFirst candidates
  where
    findFirst [] = pure (Left "no kubeconfig found for the local RKE2 cluster")
    findFirst (candidate : rest) = do
        exists <- doesFileExist candidate
        if exists then pure (Right candidate) else findFirst rest

kubectlEnv :: IO (Either String [(String, String)])
kubectlEnv = do
    kubeconfigResult <- resolveLocalKubeconfig
    case kubeconfigResult of
        Left err -> pure (Left err)
        Right kubeconfigPath ->
            Right . upsertEnv "KUBECONFIG" kubeconfigPath <$> baseEnvironment

baseEnvironment :: IO [(String, String)]
baseEnvironment = do
    currentEnv <- getEnvironment
    let path = maybe "" id (lookup "PATH" currentEnv)
        home = maybe "" id (lookup "HOME" currentEnv)
        lang = maybe "C.UTF-8" id (lookup "LANG" currentEnv)
    pure
        ( [("PATH", path), ("HOME", home), ("LANG", lang)]
            ++ maybe [] (\term -> [("TERM", term)]) (lookup "TERM" currentEnv)
        )

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv key value environment = (key, value) : filter ((/= key) . fst) environment

withMinioPortForward :: (Int -> IO a) -> IO (Either String a)
withMinioPortForward action = do
    envResult <- kubectlEnv
    case envResult of
        Left err -> pure (Left err)
        Right environment -> do
            repairResult <- repairDeletedMinioExportMountIfNeeded environment
            case repairResult of
                Left err -> pure (Left err)
                Right () -> do
                    let localPort = minioBackendLocalPort
                        portForwardProc =
                            ( proc
                                "kubectl"
                                [ "port-forward"
                                , "-n"
                                , minioNamespace
                                , "svc/" ++ minioServiceName
                                , show localPort ++ ":9000"
                                ]
                            )
                                { std_out = CreatePipe
                                , std_err = CreatePipe
                                , env = Just environment
                                , delegate_ctlc = False
                                }
                    bracket
                        (try (createProcess portForwardProc) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)))
                        ( \result ->
                            case result of
                                Left _ -> pure ()
                                Right (_, stdoutHandle, stderrHandle, processHandle) -> do
                                    terminateProcess processHandle
                                    _ <- try (waitForProcess processHandle) :: IO (Either IOException ExitCode)
                                    maybe (pure ()) hClose stdoutHandle
                                    maybe (pure ()) hClose stderrHandle
                        )
                        ( \result ->
                            case result of
                                Left exc -> pure (Left ("failed to start kubectl port-forward: " ++ show exc))
                                Right (_, _, _, _) -> do
                                    ready <- waitForPort localPort 60
                                    if ready
                                        then Right <$> action localPort
                                        else pure (Left "timed out waiting for MinIO port-forward readiness")
                        )

repairDeletedMinioExportMountIfNeeded :: [(String, String)] -> IO (Either String ())
repairDeletedMinioExportMountIfNeeded environment = do
    mountInfoResult <- readMinioMountInfo environment
    case mountInfoResult of
        Left err -> pure (Left ("failed to inspect MinIO export mount: " ++ err))
        Right mountInfo ->
            case parseDeletedMinioExportHostPath mountInfo of
                Nothing -> pure (Right ())
                Just hostPath -> do
                    putStrLn
                        ( "Detected deleted MinIO export mount at "
                            ++ hostPath
                            ++ "; recreating the host path and restarting deployment/minio."
                        )
                    recreateResult <- recreateDeletedMinioExportHostPath hostPath
                    case recreateResult of
                        Left err -> pure (Left err)
                        Right () -> do
                            restartResult <- restartMinioDeployment environment
                            case restartResult of
                                Left err -> pure (Left err)
                                Right () -> do
                                    refreshedMountInfoResult <- readMinioMountInfo environment
                                    case refreshedMountInfoResult of
                                        Left err ->
                                            pure
                                                ( Left
                                                    ( "restarted MinIO after repairing "
                                                        ++ hostPath
                                                        ++ " but failed to re-check the export mount: "
                                                        ++ err
                                                    )
                                                )
                                        Right refreshedMountInfo ->
                                            case parseDeletedMinioExportHostPath refreshedMountInfo of
                                                Nothing -> pure (Right ())
                                                Just _ ->
                                                    pure
                                                        ( Left
                                                            ( "MinIO export mount still points to a deleted host path after restart: "
                                                                ++ hostPath
                                                            )
                                                        )

readMinioMountInfo :: [(String, String)] -> IO (Either String String)
readMinioMountInfo environment = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "kubectl"
                , commandArguments =
                    [ "exec"
                    , "-n"
                    , minioNamespace
                    , "deployment/" ++ minioDeploymentName
                    , "--"
                    , "cat"
                    , "/proc/self/mountinfo"
                    ]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Nothing
                }
    pure $
        case result of
            Failure err -> Left err
            Success output ->
                case processExitCode output of
                    ExitFailure _ ->
                        Left (renderCommandFailure "kubectl exec deployment/minio -- cat /proc/self/mountinfo" output)
                    ExitSuccess -> Right (processStdout output)

recreateDeletedMinioExportHostPath :: FilePath -> IO (Either String ())
recreateDeletedMinioExportHostPath hostPath = do
    mkdirResult <-
        runCheckedCommand
            "failed to recreate deleted MinIO host path"
            CommandSpec
                { commandPath = "sudo"
                , commandArguments = ["mkdir", "-p", hostPath]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Nothing
                }
    case mkdirResult of
        Left err -> pure (Left err)
        Right () -> do
            chownResult <-
                runCheckedCommand
                    "failed to set MinIO host-path ownership"
                    CommandSpec
                        { commandPath = "sudo"
                        , commandArguments = ["chown", "-R", "1000:1000", hostPath]
                        , commandEnvironment = Nothing
                        , commandWorkingDirectory = Nothing
                        }
            case chownResult of
                Left err -> pure (Left err)
                Right () ->
                    runCheckedCommand
                        "failed to set MinIO host-path permissions"
                        CommandSpec
                            { commandPath = "sudo"
                            , commandArguments = ["chmod", "0770", hostPath]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Nothing
                            }

restartMinioDeployment :: [(String, String)] -> IO (Either String ())
restartMinioDeployment environment = do
    rolloutRestartResult <-
        runCheckedCommand
            "failed to restart deployment/minio"
            CommandSpec
                { commandPath = "kubectl"
                , commandArguments = ["rollout", "restart", "deployment/" ++ minioDeploymentName, "-n", minioNamespace]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Nothing
                }
    case rolloutRestartResult of
        Left err -> pure (Left err)
        Right () ->
            runCheckedCommand
                "deployment/minio did not become ready after restart"
                CommandSpec
                    { commandPath = "kubectl"
                    , commandArguments =
                        [ "rollout"
                        , "status"
                        , "deployment/" ++ minioDeploymentName
                        , "-n"
                        , minioNamespace
                        , "--timeout"
                        , show minioRolloutTimeoutSeconds ++ "s"
                        ]
                    , commandEnvironment = Just environment
                    , commandWorkingDirectory = Nothing
                    }

parseDeletedMinioExportHostPath :: String -> Maybe FilePath
parseDeletedMinioExportHostPath mountInfo =
    firstDeletedPath (lines mountInfo)
  where
    firstDeletedPath [] = Nothing
    firstDeletedPath (line : rest) =
        case words line of
            (_ : _ : _ : mountRoot : mountPath : _)
                | mountPath == minioExportMountPath ->
                    case stripDeletedMountSuffix mountRoot of
                        Just hostPath -> Just hostPath
                        Nothing -> firstDeletedPath rest
            _ -> firstDeletedPath rest

stripDeletedMountSuffix :: FilePath -> Maybe FilePath
stripDeletedMountSuffix mountRoot
    | deletedMountSuffix `isSuffixOf` mountRoot =
        Just (take (length mountRoot - length deletedMountSuffix) mountRoot)
    | otherwise = Nothing

runCheckedCommand :: String -> CommandSpec -> IO (Either String ())
runCheckedCommand failurePrefix spec = do
    result <- captureCommand spec
    pure $
        case result of
            Failure err -> Left (failurePrefix ++ ": " ++ err)
            Success output ->
                case processExitCode output of
                    ExitFailure _ -> Left (failurePrefix ++ ": " ++ renderCommandFailure (commandPath spec) output)
                    ExitSuccess -> Right ()

renderCommandFailure :: String -> ProcessOutput -> String
renderCommandFailure label output =
    let rendered = trim (processStderr output ++ "\n" ++ processStdout output)
     in if null rendered then label ++ " exited unsuccessfully" else rendered

waitForPort :: Int -> Int -> IO Bool
waitForPort port attemptsLeft
    | attemptsLeft <= 0 = pure False
    | otherwise = do
        open <- isPortOpen port
        if open
            then pure True
            else do
                threadDelay 250000
                waitForPort port (attemptsLeft - 1)

isPortOpen :: Int -> IO Bool
isPortOpen port = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "bash"
                , commandArguments =
                    ["-c", "echo > /dev/tcp/127.0.0.1/" ++ show port]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Nothing
                }
    pure $
        case result of
            Failure _ -> False
            Success output -> processExitCode output == ExitSuccess

readMinioCredentials :: IO (Either String (String, String))
readMinioCredentials = do
    envResult <- kubectlEnv
    case envResult of
        Left err -> pure (Left err)
        Right environment -> do
            userResult <- readSecretField environment "rootUser"
            passResult <- readSecretField environment "rootPassword"
            case (userResult, passResult) of
                (Right user, Right pass) -> pure (Right (user, pass))
                (Left err, _) -> pure (Left err)
                (_, Left err) -> pure (Left err)

readSecretField :: [(String, String)] -> String -> IO (Either String String)
readSecretField environment fieldName = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "kubectl"
                , commandArguments =
                    [ "get"
                    , "secret"
                    , minioSecretName
                    , "-n"
                    , minioNamespace
                    , "-o"
                    , "go-template={{index .data \"" ++ fieldName ++ "\" | base64decode}}"
                    ]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Nothing
                }
    case result of
        Failure err -> pure (Left ("failed to read MinIO secret field " ++ fieldName ++ ": " ++ err))
        Success output ->
            case processExitCode output of
                ExitFailure _ ->
                    pure (Left ("kubectl get secret failed for " ++ fieldName ++ ": " ++ trim (processStderr output)))
                ExitSuccess ->
                    let value = trim (processStdout output)
                     in if null value
                            then pure (Left ("MinIO secret field " ++ fieldName ++ " is empty"))
                            else pure (Right value)

ensureMinioBackendBucket :: Int -> String -> String -> IO (Either String ())
ensureMinioBackendBucket localPort accessKey secretKey = do
    let environment = minioAwsEnv accessKey secretKey
        endpoint = minioEndpointUrl localPort
    headResult <-
        captureCommand
            CommandSpec
                { commandPath = "aws"
                , commandArguments =
                    ["--endpoint-url", endpoint, "s3api", "head-bucket", "--bucket", minioBackendBucket]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Nothing
                }
    case headResult of
        Failure err -> pure (Left ("failed to check MinIO bucket: " ++ err))
        Success headOutput ->
            case processExitCode headOutput of
                ExitSuccess -> verifyMinioBackendBucketListable endpoint environment
                ExitFailure _ -> do
                    createResult <-
                        captureCommand
                            CommandSpec
                                { commandPath = "aws"
                                , commandArguments =
                                    [ "--endpoint-url"
                                    , endpoint
                                    , "s3api"
                                    , "create-bucket"
                                    , "--bucket"
                                    , minioBackendBucket
                                    ]
                                , commandEnvironment = Just environment
                                , commandWorkingDirectory = Nothing
                                }
                    case createResult of
                        Failure err -> pure (Left ("failed to create MinIO bucket: " ++ err))
                        Success createOutput ->
                            case processExitCode createOutput of
                                ExitSuccess -> verifyMinioBackendBucketListable endpoint environment
                                ExitFailure _ ->
                                    pure (Left ("aws s3api create-bucket failed: " ++ trim (processStderr createOutput)))

verifyMinioBackendBucketListable :: String -> [(String, String)] -> IO (Either String ())
verifyMinioBackendBucketListable endpoint environment = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "aws"
                , commandArguments =
                    [ "--endpoint-url"
                    , endpoint
                    , "s3api"
                    , "list-objects-v2"
                    , "--bucket"
                    , minioBackendBucket
                    , "--max-keys"
                    , "1"
                    ]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Nothing
                }
    pure $
        case result of
            Failure err -> Left ("failed to verify MinIO bucket listing: " ++ err)
            Success output ->
                case processExitCode output of
                    ExitFailure _ ->
                        Left ("MinIO backend bucket is not listable: " ++ trim (processStderr output))
                    ExitSuccess -> Right ()

bucketObjectCount :: Int -> String -> String -> IO (Either String Int)
bucketObjectCount localPort accessKey secretKey = do
    let environment = minioAwsEnv accessKey secretKey
        endpoint = minioEndpointUrl localPort
    result <-
        captureCommand
            CommandSpec
                { commandPath = "aws"
                , commandArguments =
                    [ "--endpoint-url"
                    , endpoint
                    , "s3api"
                    , "list-objects-v2"
                    , "--bucket"
                    , minioBackendBucket
                    ]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Nothing
                }
    case result of
        Failure err -> pure (Left ("failed to list MinIO bucket objects: " ++ err))
        Success output ->
            case processExitCode output of
                ExitFailure _ ->
                    pure (Left ("aws s3api list-objects-v2 failed: " ++ trim (processStderr output)))
                ExitSuccess ->
                    case eitherDecode (BL8.pack (processStdout output)) of
                        Left err -> pure (Left ("failed to parse list-objects-v2 JSON: " ++ err))
                        Right (Object payload) ->
                            case KeyMap.lookup (Key.fromString "KeyCount") payload of
                                Just (Number n) -> pure (Right (round n))
                                _ -> pure (Right 0)
                        Right _ -> pure (Right 0)

minioAwsEnv :: String -> String -> [(String, String)]
minioAwsEnv accessKey secretKey =
    [ ("AWS_ACCESS_KEY_ID", accessKey)
    , ("AWS_SECRET_ACCESS_KEY", secretKey)
    , ("AWS_REGION", minioBackendRegion)
    , ("AWS_DEFAULT_REGION", minioBackendRegion)
    , ("AWS_EC2_METADATA_DISABLED", "true")
    , ("PATH", "")
    , ("HOME", "")
    , ("LANG", "C.UTF-8")
    ]

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
