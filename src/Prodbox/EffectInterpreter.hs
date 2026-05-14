module Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffect
  , runEffectDAG
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad
  ( foldM
  , when
  )
import Data.Char (isDigit)
import Data.List
  ( intercalate
  , isInfixOf
  , sort
  )
import Data.Map.Strict qualified as Map
import Data.Set
  ( Set
  )
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Effect
  ( Effect (..)
  , Validation (..)
  )
import Prodbox.EffectDAG
  ( EffectDAG (..)
  , EffectNode (..)
  )
import Prodbox.Infra.MinioBackend
  ( ensureMinioBackendBucket
  , minioBackendRegion
  , pulumiBackendLoginTimeoutSeconds
  , pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , loadConfigFile
  , validateAndLoadSettings
  , validateAwsBootstrapConfig
  )
import Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  , commandDisplay
  , runStreamingCommand
  )
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getHomeDirectory
  )
import System.Environment
  ( getEnvironment
  )
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath
  ( (</>)
  )
import System.Info
  ( os
  )

awsValidationRetryAttempts :: Int
awsValidationRetryAttempts = 5

awsValidationRetryDelayMicroseconds :: Int
awsValidationRetryDelayMicroseconds = 2000000

data InterpreterContext = InterpreterContext
  { interpreterRepoRoot :: FilePath
  }
  deriving (Eq, Show)

runEffectDAG :: InterpreterContext -> EffectDAG -> IO (Result ())
runEffectDAG context dag = go initialPending Set.empty
 where
  nodes = effectDagNodes dag
  initialPending = Set.fromList (Map.keys nodes)

  go :: Set String -> Set String -> IO (Result ())
  go pending completed
    | Set.null pending = pure (Success ())
    | null readyIds =
        pure
          ( Failure
              ( "Effect DAG stalled with pending nodes: "
                  ++ intercalate ", " (sort (Set.toList pending))
              )
          )
    | otherwise = runReady readyIds pending completed
   where
    readyIds =
      sort
        [ effectId
        | effectId <- Set.toList pending
        , let node = nodes Map.! effectId
        , all (`Set.member` completed) (effectNodePrerequisites node)
        ]

  runReady :: [String] -> Set String -> Set String -> IO (Result ())
  runReady [] pending completed = go pending completed
  runReady (effectId : remaining) pending completed = do
    let node = nodes Map.! effectId
    outcome <- runEffect context (effectNodeEffect node)
    case outcome of
      Failure err ->
        pure
          ( Failure
              ( effectNodeId node
                  ++ " ("
                  ++ effectNodeDescription node
                  ++ "): "
                  ++ err
                  ++ "\nRemedy: "
                  ++ effectNodeRemedyHint node
              )
          )
      Success () -> runReady remaining (Set.delete effectId pending) (Set.insert effectId completed)

runEffect :: InterpreterContext -> Effect -> IO (Result ())
runEffect context effect =
  case effect of
    EmitLine text -> do
      writeOutputLine text
      pure (Success ())
    Noop -> pure (Success ())
    RunCommand spec -> runCommandEffect spec
    AssertCommandOutputContains spec expectedText ->
      assertCommandOutputContains spec expectedText
    Sequence effects -> foldM step (Success ()) effects
    Validate validation -> runValidation context validation
 where
  step :: Result () -> Effect -> IO (Result ())
  step failure@(Failure _) _ = pure failure
  step (Success ()) nextEffect = runEffect context nextEffect

runCommandEffect :: CommandSpec -> IO (Result ())
runCommandEffect spec = do
  commandResult <- runStreamingCommand spec
  pure $
    case commandResult of
      Failure err -> Failure ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
      Success ExitSuccess -> Success ()
      Success (ExitFailure code) ->
        Failure
          ( "`"
              ++ commandDisplay spec
              ++ "` exited with code "
              ++ show code
          )

assertCommandOutputContains :: CommandSpec -> String -> IO (Result ())
assertCommandOutputContains spec expectedText = do
  outputResult <- captureCommand spec
  case outputResult of
    Failure err ->
      pure (Failure ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err))
    Success output -> do
      echoProcessOutput output
      pure $
        case processExitCode output of
          ExitFailure code ->
            Failure
              ( "`"
                  ++ commandDisplay spec
                  ++ "` exited with code "
                  ++ show code
              )
          ExitSuccess ->
            if expectedText `isInfixOf` processStdout output
              then Success ()
              else
                Failure
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report required output `"
                      ++ expectedText
                      ++ "`."
                  )

runValidation :: InterpreterContext -> Validation -> IO (Result ())
runValidation context validation =
  case validation of
    RequireLinux ->
      pure
        ( if os == "linux"
            then Success ()
            else Failure "This suite requires Linux."
        )
    RequireSettings -> requireSettings
    RequireSystemd -> do
      hasSystemdDirectory <- doesDirectoryExist "/run/systemd/system"
      pure
        ( if hasSystemdDirectory
            then Success ()
            else Failure "systemd is not available on this host."
        )
    RequireTool toolName versionArgs -> requireTool toolName versionArgs
    RequireFileExists path -> requireFileExists path
    RequireHomeKubeconfig -> requireHomeKubeconfig
    RequireMachineIdentity -> requireMachineIdentity
    RequireServiceExists serviceName -> requireServiceExists serviceName
    RequireServiceActive serviceName -> requireServiceActive serviceName
    RequireAwsCredentials -> requireAwsCredentials
    RequireAwsIamHarnessReady -> requireAwsIamHarnessReady
    RequireRoute53Access -> requireRoute53Access
    RequireRoute53LifecycleCapability -> requireRoute53LifecycleCapability
    RequirePulumiLogin -> requirePulumiLogin
    RequireKubectlClusterReachable -> requireKubectlClusterReachable
    RequireUbuntu2404 -> requireUbuntu2404
 where
  requireSettings :: IO (Result ())
  requireSettings = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    pure (either Failure (const (Success ())) settingsResult)

  requireTool :: FilePath -> [String] -> IO (Result ())
  requireTool toolName versionArgs = do
    toolExists <- executableExists toolName
    if not toolExists
      then pure (Failure ("Missing required tool `" ++ toolName ++ "`."))
      else requireCapturedCommandSuccess False validationLabel spec
   where
    validationLabel = "Tool check failed"
    spec =
      CommandSpec
        { commandPath = toolName
        , commandArguments = versionArgs
        , commandEnvironment = Nothing
        , commandWorkingDirectory = Just (interpreterRepoRoot context)
        }

  executableExists :: FilePath -> IO Bool
  executableExists toolName =
    if '/' `elem` toolName
      then doesFileExist toolName
      else do
        maybeExecutable <- findExecutable toolName
        pure (maybe False (const True) maybeExecutable)

  hasHarnessAdminCredentials :: Credentials -> Bool
  hasHarnessAdminCredentials credentials =
    all
      (not . Text.null . Text.strip)
      [ access_key_id credentials
      , secret_access_key credentials
      , region credentials
      ]

  requireFileExists :: FilePath -> IO (Result ())
  requireFileExists path = do
    exists <- doesFileExist path
    pure
      ( if exists
          then Success ()
          else Failure ("Missing required file `" ++ path ++ "`.")
      )

  requireHomeKubeconfig :: IO (Result ())
  requireHomeKubeconfig = do
    homeDirectory <- getHomeDirectory
    requireFileExists (homeDirectory </> ".kube" </> "config")

  requireMachineIdentity :: IO (Result ())
  requireMachineIdentity = do
    let machineIdPath = "/etc/machine-id"
    exists <- doesFileExist machineIdPath
    if not exists
      then pure (Failure "Missing required file `/etc/machine-id`.")
      else do
        machineId <- trimTrailingNewlines <$> readFile machineIdPath
        pure
          ( if null machineId
              then Failure "`/etc/machine-id` is empty."
              else Success ()
          )

  requireServiceExists :: String -> IO (Result ())
  requireServiceExists serviceName = do
    outputResult <-
      captureCommand
        CommandSpec
          { commandPath = "systemctl"
          , commandArguments = ["show", "--property=LoadState", "--value", serviceName]
          , commandEnvironment = Nothing
          , commandWorkingDirectory = Just (interpreterRepoRoot context)
          }
    pure $
      case outputResult of
        Failure err ->
          Failure
            ( "Failed to validate service `"
                ++ serviceName
                ++ "`: "
                ++ err
            )
        Success output ->
          case processExitCode output of
            ExitFailure code ->
              Failure
                ( "Failed to inspect service `"
                    ++ serviceName
                    ++ "` (exit code "
                    ++ show code
                    ++ ")"
                    ++ toolOutputSuffix output
                )
            ExitSuccess ->
              case trimTrailingNewlines (processStdout output) of
                "" -> Failure ("Service `" ++ serviceName ++ "` is not installed.")
                "not-found" -> Failure ("Service `" ++ serviceName ++ "` is not installed.")
                _ -> Success ()

  requireServiceActive :: String -> IO (Result ())
  requireServiceActive serviceName =
    requireCapturedCommandSuccess
      False
      ("Service `" ++ serviceName ++ "` is not active")
      CommandSpec
        { commandPath = "systemctl"
        , commandArguments = ["is-active", serviceName]
        , commandEnvironment = Nothing
        , commandWorkingDirectory = Just (interpreterRepoRoot context)
        }

  requireAwsCredentials :: IO (Result ())
  requireAwsCredentials = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        environment <- awsCommandEnvironment settings
        requireAwsValidationCommandSuccess
          "AWS credential check failed"
          CommandSpec
            { commandPath = "aws"
            , commandArguments = ["sts", "get-caller-identity", "--output", "json"]
            , commandEnvironment = Just environment
            , commandWorkingDirectory = Just (interpreterRepoRoot context)
            }

  requireAwsIamHarnessReady :: IO (Result ())
  requireAwsIamHarnessReady = do
    configResult <- loadConfigFile (interpreterRepoRoot context)
    pure $
      case configResult of
        Left err -> Failure err
        Right config ->
          case validateAwsBootstrapConfig config of
            Left err -> Failure err
            Right () ->
              if hasHarnessAdminCredentials (aws_admin_for_test_simulation config)
                then Success ()
                else
                  Failure
                    "Native IAM validation requires aws_admin_for_test_simulation.access_key_id, aws_admin_for_test_simulation.secret_access_key, and aws_admin_for_test_simulation.region in prodbox-config.dhall."

  requireRoute53Access :: IO (Result ())
  requireRoute53Access = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        environment <- awsCommandEnvironment settings
        let zoneId = Text.unpack (zone_id (route53 (validatedConfig settings)))
        requireAwsValidationCommandSuccess
          "Route 53 access check failed"
          CommandSpec
            { commandPath = "aws"
            , commandArguments = ["route53", "get-hosted-zone", "--id", zoneId, "--output", "json"]
            , commandEnvironment = Just environment
            , commandWorkingDirectory = Just (interpreterRepoRoot context)
            }

  requireRoute53LifecycleCapability :: IO (Result ())
  requireRoute53LifecycleCapability = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        environment <- awsCommandEnvironment settings
        let configuredZoneId = Text.unpack (zone_id (route53 (validatedConfig settings)))
        baseZoneResult <-
          captureAwsValidationCommandOutput
            "Route 53 lifecycle capability check failed"
            CommandSpec
              { commandPath = "aws"
              , commandArguments =
                  [ "route53"
                  , "get-hosted-zone"
                  , "--id"
                  , configuredZoneId
                  , "--query"
                  , "HostedZone.Name"
                  , "--output"
                  , "text"
                  ]
              , commandEnvironment = Just environment
              , commandWorkingDirectory = Just (interpreterRepoRoot context)
              }
        case baseZoneResult of
          Failure err -> pure (Failure err)
          Success baseZoneOutput -> do
            let baseZoneName = trimTrailingDot (trimTrailingNewlines (processStdout baseZoneOutput))
            if null baseZoneName
              then
                pure (Failure "Route 53 lifecycle capability check failed: configured hosted zone name was empty.")
              else do
                nonce <- route53LifecycleNonce
                let childZoneName = "prodbox-route53-prereq-" ++ nonce ++ "." ++ baseZoneName
                    callerReference = "prodbox-route53-prereq-" ++ nonce
                createZoneResult <-
                  captureAwsValidationCommandOutput
                    "Route 53 lifecycle capability check failed"
                    CommandSpec
                      { commandPath = "aws"
                      , commandArguments =
                          [ "route53"
                          , "create-hosted-zone"
                          , "--name"
                          , childZoneName
                          , "--caller-reference"
                          , callerReference
                          , "--query"
                          , "HostedZone.Id"
                          , "--output"
                          , "text"
                          ]
                      , commandEnvironment = Just environment
                      , commandWorkingDirectory = Just (interpreterRepoRoot context)
                      }
                case createZoneResult of
                  Failure err -> pure (Failure err)
                  Success createZoneOutput -> do
                    let createdZoneId = trimTrailingNewlines (processStdout createZoneOutput)
                    if null createdZoneId
                      then
                        pure
                          ( Failure
                              "Route 53 lifecycle capability check failed: create-hosted-zone did not return a hosted zone id."
                          )
                      else
                        requireAwsValidationCommandSuccess
                          "Route 53 lifecycle capability cleanup failed"
                          CommandSpec
                            { commandPath = "aws"
                            , commandArguments =
                                [ "route53"
                                , "delete-hosted-zone"
                                , "--id"
                                , createdZoneId
                                ]
                            , commandEnvironment = Just environment
                            , commandWorkingDirectory = Just (interpreterRepoRoot context)
                            }

  requirePulumiLogin :: IO (Result ())
  requirePulumiLogin = do
    portForwardResult <-
      withMinioPortForward $ \localPort -> do
        credentialsResult <- readMinioCredentials
        case credentialsResult of
          Left err -> pure (Failure ("Pulumi login check failed: " ++ err))
          Right (accessKey, secretKey) -> do
            bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
            case bucketResult of
              Left err -> pure (Failure ("Pulumi login check failed: " ++ err))
              Right () -> do
                environment <- pulumiPrerequisiteEnvironment localPort accessKey secretKey
                outputResult <-
                  captureCommand
                    CommandSpec
                      { commandPath = "timeout"
                      , commandArguments =
                          [ "--kill-after=10s"
                          , show pulumiBackendLoginTimeoutSeconds
                          , "pulumi"
                          , "login"
                          , pulumiBackendUrl localPort
                          , "--non-interactive"
                          ]
                      , commandEnvironment = Just environment
                      , commandWorkingDirectory = Just (interpreterRepoRoot context)
                      }
                pure $
                  case outputResult of
                    Failure err ->
                      Failure
                        ( "Pulumi login check failed for `pulumi login "
                            ++ pulumiBackendUrl localPort
                            ++ " --non-interactive`: "
                            ++ err
                        )
                    Success output ->
                      case processExitCode output of
                        ExitSuccess -> Success ()
                        ExitFailure 124 ->
                          Failure
                            ( "Pulumi login check failed: `pulumi login "
                                ++ pulumiBackendUrl localPort
                                ++ " --non-interactive` timed out after "
                                ++ show pulumiBackendLoginTimeoutSeconds
                                ++ " seconds."
                            )
                        ExitFailure code ->
                          Failure
                            ( "Pulumi login check failed for `pulumi login "
                                ++ pulumiBackendUrl localPort
                                ++ " --non-interactive` (exit code "
                                ++ show code
                                ++ ")"
                                ++ toolOutputSuffix output
                            )
    case portForwardResult of
      Left err -> pure (Failure ("Pulumi login check failed: " ++ err))
      Right result -> pure result

  requireKubectlClusterReachable :: IO (Result ())
  requireKubectlClusterReachable =
    requireCapturedCommandSuccess
      True
      "Kubernetes cluster check failed"
      CommandSpec
        { commandPath = "kubectl"
        , commandArguments = ["cluster-info"]
        , commandEnvironment = Nothing
        , commandWorkingDirectory = Just (interpreterRepoRoot context)
        }

  requireUbuntu2404 :: IO (Result ())
  requireUbuntu2404 = do
    osReleaseExists <- doesFileExist "/etc/os-release"
    if not osReleaseExists
      then pure (Failure "Missing /etc/os-release; cannot validate Ubuntu 24.04 support.")
      else do
        osReleaseFields <- parseOsRelease <$> readFile "/etc/os-release"
        let distroId = lookup "ID" osReleaseFields
            versionId = lookup "VERSION_ID" osReleaseFields
        pure
          ( case (distroId, versionId) of
              (Just "ubuntu", Just "24.04") -> Success ()
              _ -> Failure "This suite requires Ubuntu 24.04 LTS."
          )

pulumiPrerequisiteEnvironment :: Int -> String -> String -> IO [(String, String)]
pulumiPrerequisiteEnvironment localPort accessKey secretKey = do
  currentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" currentEnv)
      home = maybe "" id (lookup "HOME" currentEnv)
  pure
    [ ("AWS_ACCESS_KEY_ID", accessKey)
    , ("AWS_SECRET_ACCESS_KEY", secretKey)
    , ("AWS_REGION", minioBackendRegion)
    , ("AWS_DEFAULT_REGION", minioBackendRegion)
    , ("AWS_EC2_METADATA_DISABLED", "true")
    , ("PULUMI_BACKEND_URL", pulumiBackendUrl localPort)
    , ("PULUMI_CONFIG_PASSPHRASE", "")
    , ("PULUMI_SKIP_UPDATE_CHECK", "true")
    , ("PATH", path)
    , ("HOME", home)
    , ("LANG", "C.UTF-8")
    ]

requireCapturedCommandSuccess :: Bool -> String -> CommandSpec -> IO (Result ())
requireCapturedCommandSuccess echoOutput failureLabel spec = do
  outputResult <- captureCommand spec
  case outputResult of
    Failure err ->
      pure
        ( Failure
            ( failureLabel
                ++ " for `"
                ++ commandDisplay spec
                ++ "`: "
                ++ err
            )
        )
    Success output -> do
      when echoOutput (echoProcessOutput output)
      pure $
        case processExitCode output of
          ExitSuccess -> Success ()
          ExitFailure code ->
            Failure
              ( failureLabel
                  ++ " for `"
                  ++ commandDisplay spec
                  ++ "` (exit code "
                  ++ show code
                  ++ ")"
                  ++ toolOutputSuffix output
              )

requireAwsValidationCommandSuccess :: String -> CommandSpec -> IO (Result ())
requireAwsValidationCommandSuccess failureLabel spec =
  toUnit <$> captureAwsValidationCommandOutput failureLabel spec
 where
  toUnit :: Result ProcessOutput -> Result ()
  toUnit (Failure err) = Failure err
  toUnit (Success _) = Success ()

captureAwsValidationCommandOutput :: String -> CommandSpec -> IO (Result ProcessOutput)
captureAwsValidationCommandOutput failureLabel spec =
  go awsValidationRetryAttempts
 where
  go :: Int -> IO (Result ProcessOutput)
  go attemptsRemaining = do
    outputResult <- captureCommand spec
    case outputResult of
      Failure err ->
        pure
          ( Failure
              ( failureLabel
                  ++ " for `"
                  ++ commandDisplay spec
                  ++ "`: "
                  ++ err
              )
          )
      Success output ->
        case processExitCode output of
          ExitSuccess -> pure (Success output)
          ExitFailure code
            | attemptsRemaining > 1 && isRetryableAwsValidationFailure output -> do
                threadDelay awsValidationRetryDelayMicroseconds
                go (attemptsRemaining - 1)
            | otherwise ->
                pure
                  ( Failure
                      ( failureLabel
                          ++ " for `"
                          ++ commandDisplay spec
                          ++ "` (exit code "
                          ++ show code
                          ++ ")"
                          ++ toolOutputSuffix output
                      )
                  )

isRetryableAwsValidationFailure :: ProcessOutput -> Bool
isRetryableAwsValidationFailure output =
  any (`Text.isInfixOf` renderedOutput) retryableFragments
 where
  renderedOutput =
    Text.toLower
      ( Text.pack (processStdout output)
          <> Text.pack "\n"
          <> Text.pack (processStderr output)
      )
  retryableFragments =
    map
      Text.pack
      [ "invalidclienttokenid"
      , "security token included in the request is invalid"
      , "signaturedoesnotmatch"
      , "unrecognizedclientexception"
      , "requestexpired"
      , "expiredtoken"
      ]

echoProcessOutput :: ProcessOutput -> IO ()
echoProcessOutput output = do
  writeOutput (processStdout output)
  writeDiagnostic (processStderr output)

awsCommandEnvironment :: ValidatedSettings -> IO [(String, String)]
awsCommandEnvironment settings = do
  currentEnvironment <- getEnvironment
  pure (overlayAwsCredentials currentEnvironment (aws (validatedConfig settings)))

parseOsRelease :: String -> [(String, String)]
parseOsRelease contents =
  foldr collect [] (lines contents)
 where
  collect :: String -> [(String, String)] -> [(String, String)]
  collect rawLine fields =
    case break (== '=') rawLine of
      ([], _) -> fields
      (_, []) -> fields
      ('#' : _, _) -> fields
      (key, _ : value) -> (key, stripQuotes value) : fields

stripQuotes :: String -> String
stripQuotes value =
  case value of
    '"' : remaining -> reverse (dropWhile (== '"') (reverse remaining))
    _ -> value

toolOutputSuffix :: ProcessOutput -> String
toolOutputSuffix output =
  case filter (not . null) [processStdout output, processStderr output] of
    [] -> ""
    rendered -> ": " ++ intercalate " | " (map trimTrailingNewlines rendered)

trimTrailingNewlines :: String -> String
trimTrailingNewlines = reverse . dropWhile (== '\n') . reverse

trimTrailingDot :: String -> String
trimTrailingDot value =
  if not (null value) && last value == '.'
    then init value
    else value

route53LifecycleNonce :: IO String
route53LifecycleNonce =
  filter isDigit . show <$> getPOSIXTime
