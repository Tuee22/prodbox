{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.MinioBackend
    ( minioBackendBucket,
      minioBackendLocalPort,
      minioBackendRegion,
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
    )
where

import Control.Concurrent (threadDelay)
import Control.Exception
    ( IOException,
      bracket,
      try,
    )
import Data.Aeson
    ( Value (..),
      eitherDecode,
    )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy.Char8 as BL8
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
    ( CommandSpec (..),
      ProcessOutput (..),
      captureCommand,
    )
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.Process
    ( CreateProcess (..),
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

minioNamespace :: String
minioNamespace = "prodbox"

minioSecretName :: String
minioSecretName = "minio"

minioServiceName :: String
minioServiceName = "minio"

minioEndpointUrl :: Int -> String
minioEndpointUrl localPort = "http://127.0.0.1:" ++ show localPort

pulumiBackendUrl :: Int -> String
pulumiBackendUrl localPort =
    "s3://" ++ minioBackendBucket
        ++ "?region=" ++ minioBackendRegion
        ++ "&endpoint=127.0.0.1:" ++ show localPort
        ++ "&disableSSL=true"
        ++ "&s3ForcePathStyle=true"

resolveLocalKubeconfig :: IO (Either String FilePath)
resolveLocalKubeconfig = do
    kubeconfigEnv <- lookupEnv "KUBECONFIG"
    homeDir <- lookupEnv "HOME"
    let candidates =
            [ path
            | Just path <-
                [ kubeconfigEnv,
                  fmap (</> ".kube" </> "config") homeDir,
                  Just "/etc/rancher/rke2/rke2.yaml"
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
        Right kubeconfigPath -> do
            baseEnv <- baseEnvironment
            pure (Right (upsertEnv "KUBECONFIG" kubeconfigPath baseEnv))

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
            let localPort = minioBackendLocalPort
                portForwardProc =
                    (proc "kubectl"
                        [ "port-forward",
                          "-n", minioNamespace,
                          "svc/" ++ minioServiceName,
                          show localPort ++ ":9000"
                        ]
                    )
                    { std_out = CreatePipe,
                      std_err = CreatePipe,
                      env = Just environment,
                      delegate_ctlc = False
                    }
            bracket
                (try (createProcess portForwardProc) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)))
                (\result ->
                    case result of
                        Left _ -> pure ()
                        Right (_, stdoutHandle, stderrHandle, processHandle) -> do
                            terminateProcess processHandle
                            _ <- try (waitForProcess processHandle) :: IO (Either IOException ExitCode)
                            maybe (pure ()) hClose stdoutHandle
                            maybe (pure ()) hClose stderrHandle
                )
                (\result ->
                    case result of
                        Left exc -> pure (Left ("failed to start kubectl port-forward: " ++ show exc))
                        Right (_, _, _, _) -> do
                            ready <- waitForPort localPort 60
                            if ready
                                then Right <$> action localPort
                                else pure (Left "timed out waiting for MinIO port-forward readiness")
                )

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
                { commandPath = "bash",
                  commandArguments =
                    ["-c", "echo > /dev/tcp/127.0.0.1/" ++ show port],
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Nothing
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
                { commandPath = "kubectl",
                  commandArguments =
                    [ "get", "secret", minioSecretName,
                      "-n", minioNamespace,
                      "-o", "go-template={{index .data \"" ++ fieldName ++ "\" | base64decode}}"
                    ],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Nothing
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
                { commandPath = "aws",
                  commandArguments =
                    ["--endpoint-url", endpoint, "s3api", "head-bucket", "--bucket", minioBackendBucket],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Nothing
                }
    case headResult of
        Failure err -> pure (Left ("failed to check MinIO bucket: " ++ err))
        Success headOutput ->
            case processExitCode headOutput of
                ExitSuccess -> pure (Right ())
                ExitFailure _ -> do
                    createResult <-
                        captureCommand
                            CommandSpec
                                { commandPath = "aws",
                                  commandArguments =
                                    [ "--endpoint-url", endpoint,
                                      "s3api", "create-bucket",
                                      "--bucket", minioBackendBucket
                                    ],
                                  commandEnvironment = Just environment,
                                  commandWorkingDirectory = Nothing
                                }
                    case createResult of
                        Failure err -> pure (Left ("failed to create MinIO bucket: " ++ err))
                        Success createOutput ->
                            case processExitCode createOutput of
                                ExitSuccess -> pure (Right ())
                                ExitFailure _ ->
                                    pure (Left ("aws s3api create-bucket failed: " ++ trim (processStderr createOutput)))

bucketObjectCount :: Int -> String -> String -> IO (Either String Int)
bucketObjectCount localPort accessKey secretKey = do
    let environment = minioAwsEnv accessKey secretKey
        endpoint = minioEndpointUrl localPort
    result <-
        captureCommand
            CommandSpec
                { commandPath = "aws",
                  commandArguments =
                    [ "--endpoint-url", endpoint,
                      "s3api", "list-objects-v2",
                      "--bucket", minioBackendBucket
                    ],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Nothing
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
    [ ("AWS_ACCESS_KEY_ID", accessKey),
      ("AWS_SECRET_ACCESS_KEY", secretKey),
      ("AWS_REGION", minioBackendRegion),
      ("AWS_DEFAULT_REGION", minioBackendRegion),
      ("AWS_EC2_METADATA_DISABLED", "true"),
      ("PATH", ""),
      ("HOME", ""),
      ("LANG", "C.UTF-8")
    ]

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
