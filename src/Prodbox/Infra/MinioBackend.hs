{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.MinioBackend
  ( minioBackendBucket
  , minioBackendLocalPort
  , minioBackendRegion
  , pulumiBackendLoginTimeoutSeconds
  , minioNamespace
  , minioSecretName
  , minioServiceName
  , withMinioPortForward
  , withCurrentMinioPortForward
  , readMinioCredentials
  , ensureMinioBackendBucket
  , bucketObjectCount
  , minioGetObjectArgs
  , minioPutObjectArgs
  , pulumiBackendUrl
  , minioEndpointUrl
  , localKubeconfigCandidates
  , firstReadableKubeconfigCandidate
  , resolveLocalKubeconfig
  , minioAwsEnv
  , parseDeletedMinioExportHostPath
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( IOException
  , bracket
  , try
  )
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isSuffixOf)
import Data.Maybe (maybeToList)
import Data.Text qualified as Text
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Error (AppError)
import Prodbox.Result (Result (..))
import Prodbox.Service
  ( MinIOError
  , runMinIOWithEnv
  , serviceErrorMessage
  , toServiceError
  )
import Prodbox.Subprocess
  ( BackgroundProcess
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import System.Directory
  ( Permissions
  , doesFileExist
  , getPermissions
  , readable
  )
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

minioBackendBucket :: String
minioBackendBucket = "prodbox-state"

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

localRke2KubeconfigPath :: FilePath
localRke2KubeconfigPath = "/etc/rancher/rke2/rke2.yaml"

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
  readableCandidate <-
    firstReadableKubeconfigCandidate (localKubeconfigCandidates homeDir kubeconfigEnv)
  pure
    (maybe (Left "no readable kubeconfig found for the local RKE2 cluster") Right readableCandidate)

-- | Candidate order for the home-local MinIO backend. The per-run Pulumi
-- backend is anchored in the local RKE2 cluster, so callers must not inherit
-- an AWS-substrate @KUBECONFIG@ when they open the MinIO port-forward.
localKubeconfigCandidates :: Maybe FilePath -> Maybe FilePath -> [FilePath]
localKubeconfigCandidates homeDir kubeconfigEnv =
  [localRke2KubeconfigPath]
    ++ maybe [] (\home -> [home </> ".kube" </> "config"]) homeDir
    ++ maybeToList kubeconfigEnv

firstReadableKubeconfigCandidate :: [FilePath] -> IO (Maybe FilePath)
firstReadableKubeconfigCandidate [] = pure Nothing
firstReadableKubeconfigCandidate (candidate : rest) = do
  candidateUsable <- isReadableFile candidate
  if candidateUsable
    then pure (Just candidate)
    else firstReadableKubeconfigCandidate rest

isReadableFile :: FilePath -> IO Bool
isReadableFile path = do
  exists <- doesFileExist path
  if not exists
    then pure False
    else do
      permissionResult <- try (getPermissions path) :: IO (Either IOException Permissions)
      pure (either (const False) readable permissionResult)

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
          withMinioPortForwardEnv (Just environment) localPort action

-- | Port-forward the MinIO Service in the caller's active kubeconfig.
--
-- The Pulumi backend helpers use 'withMinioPortForward' above because
-- backend state is anchored in the home-local RKE2 cluster even while
-- AWS-substrate tests temporarily switch kubeconfig contexts. Chart
-- bootstrap paths need the opposite behavior: they read active-cluster
-- credentials and write substrate-local object-store data into that same
-- cluster's MinIO.
withCurrentMinioPortForward :: (Int -> IO a) -> IO (Either String a)
withCurrentMinioPortForward =
  withMinioPortForwardEnv Nothing minioBackendLocalPort

withMinioPortForwardEnv
  :: Maybe [(String, String)]
  -> Int
  -> (Int -> IO a)
  -> IO (Either String a)
withMinioPortForwardEnv environment localPort action =
  bracket
    ( startBackgroundProcess
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments =
              [ "port-forward"
              , "-n"
              , minioNamespace
              , "svc/" ++ minioServiceName
              , show localPort ++ ":9000"
              ]
          , subprocessEnvironment = environment
          , subprocessWorkingDirectory = Nothing
          }
    )
    cleanupBackgroundProcess
    (handlePortForwardResult localPort action)

handlePortForwardResult
  :: Int -> (Int -> IO value) -> Either AppError BackgroundProcess -> IO (Either String value)
handlePortForwardResult localPort action result =
  case result of
    Left err -> pure (Left (showBackgroundProcessError err))
    Right _ -> do
      ready <- waitForPort localPort 60
      if ready
        then Right <$> action localPort
        else pure (Left "timed out waiting for MinIO port-forward readiness")

cleanupBackgroundProcess :: Either a BackgroundProcess -> IO ()
cleanupBackgroundProcess result =
  case result of
    Left _ -> pure ()
    Right process -> stopBackgroundProcess process

showBackgroundProcessError :: (Show errorType) => errorType -> String
showBackgroundProcessError = show

repairDeletedMinioExportMountIfNeeded :: [(String, String)] -> IO (Either String ())
repairDeletedMinioExportMountIfNeeded environment = do
  mountInfoResult <- readMinioMountInfo environment
  case mountInfoResult of
    Left err -> pure (Left ("failed to inspect MinIO export mount: " ++ err))
    Right mountInfo ->
      case parseDeletedMinioExportHostPath mountInfo of
        Nothing -> pure (Right ())
        Just hostPath -> do
          writeOutputLine
            ( "Detected deleted MinIO export mount at "
                ++ hostPath
                ++ "; recreating the host path and restarting statefulset/minio."
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
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "exec"
            , "-n"
            , minioNamespace
            , "statefulset/" ++ minioDeploymentName
            , "--"
            , "cat"
            , "/proc/self/mountinfo"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $
    case result of
      Failure err -> Left err
      Success output ->
        case processExitCode output of
          ExitFailure _ ->
            Left (renderCommandFailure "kubectl exec statefulset/minio -- cat /proc/self/mountinfo" output)
          ExitSuccess -> Right (processStdout output)

recreateDeletedMinioExportHostPath :: FilePath -> IO (Either String ())
recreateDeletedMinioExportHostPath hostPath = do
  mkdirResult <-
    runCheckedCommand
      "failed to recreate deleted MinIO host path"
      Subprocess
        { subprocessPath = "sudo"
        , subprocessArguments = ["mkdir", "-p", hostPath]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  case mkdirResult of
    Left err -> pure (Left err)
    Right () -> do
      chownResult <-
        runCheckedCommand
          "failed to set MinIO host-path ownership"
          Subprocess
            { subprocessPath = "sudo"
            , subprocessArguments = ["chown", "-R", "1000:1000", hostPath]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Nothing
            }
      case chownResult of
        Left err -> pure (Left err)
        Right () ->
          runCheckedCommand
            "failed to set MinIO host-path permissions"
            Subprocess
              { subprocessPath = "sudo"
              , subprocessArguments = ["chmod", "0770", hostPath]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Nothing
              }

restartMinioDeployment :: [(String, String)] -> IO (Either String ())
restartMinioDeployment environment = do
  rolloutRestartResult <-
    runCheckedCommand
      "failed to restart statefulset/minio"
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            ["rollout", "restart", "statefulset/" ++ minioDeploymentName, "-n", minioNamespace]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  case rolloutRestartResult of
    Left err -> pure (Left err)
    Right () ->
      runCheckedCommand
        "statefulset/minio did not become ready after restart"
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments =
              [ "rollout"
              , "status"
              , "statefulset/" ++ minioDeploymentName
              , "-n"
              , minioNamespace
              , "--timeout"
              , show minioRolloutTimeoutSeconds ++ "s"
              ]
          , subprocessEnvironment = Just environment
          , subprocessWorkingDirectory = Nothing
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

runCheckedCommand :: String -> Subprocess -> IO (Either String ())
runCheckedCommand failurePrefix spec = do
  result <- captureSubprocessResult spec
  pure $
    case result of
      Failure err -> Left (failurePrefix ++ ": " ++ err)
      Success output ->
        case processExitCode output of
          ExitFailure _ -> Left (failurePrefix ++ ": " ++ renderCommandFailure (subprocessPath spec) output)
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
    captureSubprocessResult
      Subprocess
        { subprocessPath = "bash"
        , subprocessArguments =
            ["-c", "echo > /dev/tcp/127.0.0.1/" ++ show port]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
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
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , minioSecretName
            , "-n"
            , minioNamespace
            , "-o"
            , "go-template={{index .data \"" ++ fieldName ++ "\" | base64decode}}"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
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
    runMinIOWithEnv
      (Just environment)
      ["--endpoint-url", endpoint, "s3api", "head-bucket", "--bucket", minioBackendBucket]
  case headResult of
    Left err -> pure (Left ("failed to check MinIO bucket: " ++ renderMinIOError err))
    Right headOutput ->
      case processExitCode headOutput of
        ExitSuccess -> verifyMinioBackendBucketListable endpoint environment
        ExitFailure _ -> do
          createResult <-
            runMinIOWithEnv
              (Just environment)
              [ "--endpoint-url"
              , endpoint
              , "s3api"
              , "create-bucket"
              , "--bucket"
              , minioBackendBucket
              ]
          case createResult of
            Left err -> pure (Left ("failed to create MinIO bucket: " ++ renderMinIOError err))
            Right createOutput ->
              case processExitCode createOutput of
                ExitSuccess -> verifyMinioBackendBucketListable endpoint environment
                ExitFailure _ ->
                  pure (Left ("aws s3api create-bucket failed: " ++ trim (processStderr createOutput)))

verifyMinioBackendBucketListable :: String -> [(String, String)] -> IO (Either String ())
verifyMinioBackendBucketListable endpoint environment = do
  result <-
    runMinIOWithEnv
      (Just environment)
      [ "--endpoint-url"
      , endpoint
      , "s3api"
      , "list-objects-v2"
      , "--bucket"
      , minioBackendBucket
      , "--max-keys"
      , "1"
      ]
  pure $
    case result of
      Left err -> Left ("failed to verify MinIO bucket listing: " ++ renderMinIOError err)
      Right output ->
        case processExitCode output of
          ExitFailure _ ->
            Left ("MinIO backend bucket is not listable: " ++ trim (processStderr output))
          ExitSuccess -> Right ()

bucketObjectCount :: Int -> String -> String -> IO (Either String Int)
bucketObjectCount localPort accessKey secretKey = do
  let environment = minioAwsEnv accessKey secretKey
      endpoint = minioEndpointUrl localPort
  result <-
    runMinIOWithEnv
      (Just environment)
      [ "--endpoint-url"
      , endpoint
      , "s3api"
      , "list-objects-v2"
      , "--bucket"
      , minioBackendBucket
      ]
  case result of
    Left err -> pure (Left ("failed to list MinIO bucket objects: " ++ renderMinIOError err))
    Right output ->
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

minioGetObjectArgs :: String -> String -> String -> FilePath -> [String]
minioGetObjectArgs endpoint bucket key outputPath =
  [ "--endpoint-url"
  , endpoint
  , "s3api"
  , "get-object"
  , "--bucket"
  , bucket
  , "--key"
  , key
  , outputPath
  ]

minioPutObjectArgs :: String -> String -> String -> FilePath -> [String]
minioPutObjectArgs endpoint bucket key inputPath =
  [ "--endpoint-url"
  , endpoint
  , "s3api"
  , "put-object"
  , "--bucket"
  , bucket
  , "--key"
  , key
  , "--body"
  , inputPath
  ]

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

renderMinIOError :: MinIOError -> String
renderMinIOError = Text.unpack . serviceErrorMessage . toServiceError

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
