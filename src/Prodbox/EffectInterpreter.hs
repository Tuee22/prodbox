module Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffect
  , runEffectDAG
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (bracketOnError)
import Control.Monad
  ( foldM
  , when
  )
import Data.Char (isDigit)
import Data.List
  ( intercalate
  , isInfixOf
  , sortBy
  )
import Data.Map.Strict qualified as Map
import Data.Ord
  ( comparing
  )
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
import Prodbox.PrerequisiteId
  ( PrerequisiteId
  , prerequisiteIdText
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , Route53Section (..)
  , SesSection (..)
  , ValidatedSettings (..)
  , loadConfigFile
  , validateAndLoadSettings
  , validateAwsBootstrapConfig
  , validateOperationalAwsCredentials
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , commandDisplay
  , runSubprocessStreaming
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

-- | Interpreter-boundary memo of satisfied node effects within one `runEffectDAG` run.
--
-- Per [prerequisite_dag_system.md](../../documents/engineering/prerequisite_dag_system.md) §3
-- ("no duplicate execution of the same satisfied node within one run") and pure_fp_standards
-- §3.2 (mutable/threaded state is boundary-only), this is an immutable accumulator threaded
-- through the IO scheduling loop — it never escapes the interpreter boundary and is keyed on
-- the node `Effect` so an already-satisfied probe (the full Dhall decode for `RequireSettings`,
-- a `RequireTool` invocation, …) executes at most once per run even when several distinct nodes
-- carry the same effect. `Effect` derives only `Eq`, so the memo is an association list looked
-- up by `Eq`.
newtype SatisfiedEffectMemo = SatisfiedEffectMemo [Effect]

emptySatisfiedEffectMemo :: SatisfiedEffectMemo
emptySatisfiedEffectMemo = SatisfiedEffectMemo []

isEffectSatisfied :: Effect -> SatisfiedEffectMemo -> Bool
isEffectSatisfied effect (SatisfiedEffectMemo satisfied) = effect `elem` satisfied

rememberSatisfiedEffect :: Effect -> SatisfiedEffectMemo -> SatisfiedEffectMemo
rememberSatisfiedEffect effect memo@(SatisfiedEffectMemo satisfied)
  | isEffectSatisfied effect memo = memo
  | otherwise = SatisfiedEffectMemo (effect : satisfied)

runEffectDAG :: InterpreterContext -> EffectDAG -> IO (Result ())
runEffectDAG context dag = go initialPending Set.empty emptySatisfiedEffectMemo
 where
  nodes = effectDagNodes dag
  initialPending = Set.fromList (Map.keys nodes)

  sortByText :: [PrerequisiteId] -> [PrerequisiteId]
  sortByText = sortBy (comparing prerequisiteIdText)

  go :: Set PrerequisiteId -> Set PrerequisiteId -> SatisfiedEffectMemo -> IO (Result ())
  go pending completed memo
    | Set.null pending = pure (Success ())
    | null readyIds =
        pure
          ( Failure
              ( "Effect DAG stalled with pending nodes: "
                  ++ intercalate ", " (map prerequisiteIdText (sortByText (Set.toList pending)))
              )
          )
    | otherwise = runReady readyIds pending completed memo
   where
    readyIds =
      sortBy
        (comparing prerequisiteIdText)
        [ effectId
        | effectId <- Set.toList pending
        , let node = nodes Map.! effectId
        , all (`Set.member` completed) (effectNodePrerequisites node)
        ]

  runReady
    :: [PrerequisiteId]
    -> Set PrerequisiteId
    -> Set PrerequisiteId
    -> SatisfiedEffectMemo
    -> IO (Result ())
  runReady [] pending completed memo = go pending completed memo
  runReady (effectId : remaining) pending completed memo = do
    let node = nodes Map.! effectId
        effect = effectNodeEffect node
    outcome <-
      if isEffectSatisfied effect memo
        then pure (Success ())
        else runEffect context effect
    case outcome of
      Failure err ->
        pure
          ( Failure
              ( prerequisiteIdText (effectNodeId node)
                  ++ " ("
                  ++ effectNodeDescription node
                  ++ "): "
                  ++ err
                  ++ "\nRemedy: "
                  ++ effectNodeRemedyHint node
              )
          )
      Success () ->
        runReady
          remaining
          (Set.delete effectId pending)
          (Set.insert effectId completed)
          (rememberSatisfiedEffect effect memo)

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

runCommandEffect :: Subprocess -> IO (Result ())
runCommandEffect spec = do
  commandResult <- runSubprocessStreaming spec
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

assertCommandOutputContains :: Subprocess -> String -> IO (Result ())
assertCommandOutputContains spec expectedText = do
  outputResult <- captureSubprocessResult spec
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
    RequireSesSendingIdentityVerified -> requireSesSendingIdentityVerified
    RequireSesReceiveRuleSetActive -> requireSesReceiveRuleSetActive
    RequireSesReceiveBucketAccessible -> requireSesReceiveBucketAccessible
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
      Subprocess
        { subprocessPath = toolName
        , subprocessArguments = versionArgs
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
      captureSubprocessResult
        Subprocess
          { subprocessPath = "systemctl"
          , subprocessArguments = ["show", "--property=LoadState", "--value", serviceName]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
      Subprocess
        { subprocessPath = "systemctl"
        , subprocessArguments = ["is-active", serviceName]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
        }

  requireAwsCredentials :: IO (Result ())
  requireAwsCredentials = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings ->
        -- Config now decodes locally without operational @aws.*@; this
        -- node is the AWS-credential gate, so check the operational
        -- credentials are present before spending an STS round trip. The
        -- node's remedy hint ("Run `prodbox aws setup`") is appended by
        -- the interpreter on failure.
        case validateOperationalAwsCredentials (validatedConfig settings) of
          Left err -> pure (Failure err)
          Right () -> do
            environment <- awsCommandEnvironment settings
            requireAwsValidationCommandSuccess
              "AWS credential check failed"
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments = ["sts", "get-caller-identity", "--output", "json"]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments = ["route53", "get-hosted-zone", "--id", zoneId, "--output", "json"]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
            Subprocess
              { subprocessPath = "aws"
              , subprocessArguments =
                  [ "route53"
                  , "get-hosted-zone"
                  , "--id"
                  , configuredZoneId
                  , "--query"
                  , "HostedZone.Name"
                  , "--output"
                  , "text"
                  ]
              , subprocessEnvironment = Just environment
              , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
                    Subprocess
                      { subprocessPath = "aws"
                      , subprocessArguments =
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
                      , subprocessEnvironment = Just environment
                      , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
                        -- Sprint 4.27 (audit C66): the throwaway capability-proof
                        -- hosted zone now exists. Wrap the rest of the probe in
                        -- 'bracketOnError' so any exception thrown after the create
                        -- (e.g. an async exception, or a future step inserted between
                        -- create and delete) always triggers a best-effort delete of
                        -- the proof zone — no hosted-zone leak on a mid-probe failure.
                        -- This probe is deliberately NOT a registered 'ManagedResource'
                        -- (it has no steady state to discover/reconcile), so the §3.1
                        -- totality registry stays correct without it.
                        bracketOnError
                          (pure createdZoneId)
                          deleteCapabilityProofZone
                          ( \zoneId ->
                              requireAwsValidationCommandSuccess
                                "Route 53 lifecycle capability cleanup failed"
                                (deleteHostedZoneSpec environment zoneId)
                          )
   where
    deleteHostedZoneSpec :: [(String, String)] -> String -> Subprocess
    deleteHostedZoneSpec environment zoneId =
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "route53"
            , "delete-hosted-zone"
            , "--id"
            , zoneId
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
        }
    -- \| The 'bracketOnError' cleanup handler: best-effort delete of the
    -- proof zone on the exception path. Errors here are swallowed (the
    -- original exception is rethrown by 'bracketOnError'); the goal is
    -- only to avoid leaking the zone.
    deleteCapabilityProofZone :: String -> IO ()
    deleteCapabilityProofZone zoneId = do
      settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
      case settingsResult of
        Left _ -> pure ()
        Right settings -> do
          environment <- awsCommandEnvironment settings
          _ <-
            requireAwsValidationCommandSuccess
              "Route 53 lifecycle capability cleanup failed"
              (deleteHostedZoneSpec environment zoneId)
          pure ()

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
                  captureSubprocessResult
                    Subprocess
                      { subprocessPath = "timeout"
                      , subprocessArguments =
                          [ "--kill-after=10s"
                          , show pulumiBackendLoginTimeoutSeconds
                          , "pulumi"
                          , "login"
                          , pulumiBackendUrl localPort
                          , "--non-interactive"
                          ]
                      , subprocessEnvironment = Just environment
                      , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments = ["cluster-info"]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
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

  requireSesSendingIdentityVerified :: IO (Result ())
  requireSesSendingIdentityVerified = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        let domain =
              Text.unpack
                (Text.strip (sender_domain (ses (validatedConfig settings))))
        if null domain
          then
            pure
              ( Failure
                  "ses.sender_domain must be set in prodbox-config.dhall before checking the SES sending identity. Run `prodbox aws stack aws-ses reconcile` after populating the ses.* block."
              )
          else do
            environment <- awsCommandEnvironment settings
            requireAwsValidationCommandSuccess
              "SES sending-identity verification check failed"
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments =
                    [ "ses"
                    , "get-identity-verification-attributes"
                    , "--identities"
                    , domain
                    , "--query"
                    , "VerificationAttributes." ++ domain ++ ".VerificationStatus"
                    , "--output"
                    , "text"
                    ]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
                }

  requireSesReceiveRuleSetActive :: IO (Result ())
  requireSesReceiveRuleSetActive = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        environment <- awsCommandEnvironment settings
        requireAwsValidationCommandSuccess
          "SES active receive rule set check failed"
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "ses"
                , "describe-active-receipt-rule-set"
                , "--query"
                , "Metadata.Name"
                , "--output"
                , "text"
                ]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
            }

  requireSesReceiveBucketAccessible :: IO (Result ())
  requireSesReceiveBucketAccessible = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        let bucket =
              Text.unpack (Text.strip (capture_bucket (ses (validatedConfig settings))))
        if null bucket
          then
            pure
              ( Failure
                  "ses.capture_bucket must be set in prodbox-config.dhall before checking SES capture-bucket reachability."
              )
          else do
            environment <- awsCommandEnvironment settings
            requireAwsValidationCommandSuccess
              "SES capture-bucket reachability check failed"
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments =
                    [ "s3api"
                    , "head-bucket"
                    , "--bucket"
                    , bucket
                    ]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just (interpreterRepoRoot context)
                }

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

requireCapturedCommandSuccess :: Bool -> String -> Subprocess -> IO (Result ())
requireCapturedCommandSuccess echoOutput failureLabel spec = do
  outputResult <- captureSubprocessResult spec
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

requireAwsValidationCommandSuccess :: String -> Subprocess -> IO (Result ())
requireAwsValidationCommandSuccess failureLabel spec =
  toUnit <$> captureAwsValidationCommandOutput failureLabel spec
 where
  toUnit :: Result ProcessOutput -> Result ()
  toUnit (Failure err) = Failure err
  toUnit (Success _) = Success ()

captureAwsValidationCommandOutput :: String -> Subprocess -> IO (Result ProcessOutput)
captureAwsValidationCommandOutput failureLabel spec =
  go awsValidationRetryAttempts
 where
  go :: Int -> IO (Result ProcessOutput)
  go attemptsRemaining = do
    outputResult <- captureSubprocessResult spec
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
