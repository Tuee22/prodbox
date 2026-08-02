module Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , AwsCredentialValidationBoundary (..)
  , runAwsCredentialValidationWithRetry
  , runEffect
  , runEffectWithAwsCredentialValidationBoundary
  , runEffectDAG
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad
  ( foldM
  , when
  )
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
import Prodbox.Aws.AdminCredentials (acquireAdminAwsCredentials)
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeOutput
  , writeOutputLine
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchHostProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Effect
  ( Effect (..)
  , Validation (..)
  )
import Prodbox.EffectDAG
  ( EffectDAG (..)
  , EffectNode (..)
  )
import Prodbox.Host.Substrate
  ( detectHostSubstrate
  )
import Prodbox.Infra.AwsSesStack (ensureAwsSesStackResources)
import Prodbox.Infra.MinioBackend
  ( ensureMinioBackendBucket
  , hostDirectEndpointPort
  , minioBackendRegion
  , pulumiBackendLoginTimeoutSeconds
  , pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderReadiness)
  , ProviderReadinessProbe (ProviderReadinessRoute53Zone, ProviderReadinessStsIdentity)
  )
import Prodbox.PrerequisiteId
  ( PrerequisiteId
  , prerequisiteIdText
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Ses.Readiness
  ( AwsSesReadinessScope (..)
  )
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , Route53Section (..)
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

-- | Closed validation seam for the Lifecycle-provider identity.  Production
-- dispatches the read-only STS readiness intent through the authenticated
-- Lifecycle Authority/Provider Worker path; unit tests inject this boundary
-- explicitly and therefore never gain an environment-variable or host-Vault
-- credential fallback.
data AwsCredentialValidationBoundary m = AwsCredentialValidationBoundary
  { validateAwsCredentialThroughProvider :: m (Either String ())
  , waitForAwsCredentialValidationRetry :: m ()
  }

runAwsCredentialValidationWithRetry
  :: Int
  -> AwsCredentialValidationBoundary IO
  -> IO (Result ())
runAwsCredentialValidationWithRetry remaining boundary = do
  result <- validateAwsCredentialThroughProvider boundary
  case result of
    Right () -> pure (Success ())
    Left detail
      | remaining <= 1 ->
          pure
            ( Failure
                ( "AWS credential check failed through the authenticated "
                    ++ "Lifecycle Authority/Provider Worker: "
                    ++ detail
                )
            )
      | otherwise -> do
          waitForAwsCredentialValidationRetry boundary
          runAwsCredentialValidationWithRetry (remaining - 1) boundary

productionAwsCredentialValidationBoundary
  :: InterpreterContext -> AwsCredentialValidationBoundary IO
productionAwsCredentialValidationBoundary context =
  AwsCredentialValidationBoundary
    { validateAwsCredentialThroughProvider = do
        result <-
          dispatchHostProviderIntentFresh
            LifecycleAuthorityOperator
            (interpreterRepoRoot context)
            (Text.pack "prerequisite-aws-credential-readiness")
            (ObserveProviderReadiness ProviderReadinessStsIdentity)
        pure $ case result of
          Left err -> Left (renderProviderCallerError err)
          Right _ -> Right ()
    , waitForAwsCredentialValidationRetry =
        threadDelay awsValidationRetryDelayMicroseconds
    }

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
runEffectDAG context dag =
  runEffectDAGWithAwsCredentialValidationBoundary
    context
    (productionAwsCredentialValidationBoundary context)
    dag

runEffectDAGWithAwsCredentialValidationBoundary
  :: InterpreterContext
  -> AwsCredentialValidationBoundary IO
  -> EffectDAG
  -> IO (Result ())
runEffectDAGWithAwsCredentialValidationBoundary context awsCredentialBoundary dag =
  go initialPending Set.empty emptySatisfiedEffectMemo
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
        else runEffectWithAwsCredentialValidationBoundary context awsCredentialBoundary effect
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
runEffect context =
  runEffectWithAwsCredentialValidationBoundary
    context
    (productionAwsCredentialValidationBoundary context)

runEffectWithAwsCredentialValidationBoundary
  :: InterpreterContext
  -> AwsCredentialValidationBoundary IO
  -> Effect
  -> IO (Result ())
runEffectWithAwsCredentialValidationBoundary context awsCredentialBoundary effect =
  case effect of
    EmitLine text -> do
      writeOutputLine text
      pure (Success ())
    Noop -> pure (Success ())
    RunCommand spec -> runCommandEffect spec
    AssertCommandOutputContains spec expectedText ->
      assertCommandOutputContains spec expectedText
    Sequence effects -> foldM step (Success ()) effects
    Validate validation -> runValidation context awsCredentialBoundary validation
 where
  step :: Result () -> Effect -> IO (Result ())
  step failure@(Failure _) _ = pure failure
  step (Success ()) nextEffect =
    runEffectWithAwsCredentialValidationBoundary context awsCredentialBoundary nextEffect

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

runValidation
  :: InterpreterContext
  -> AwsCredentialValidationBoundary IO
  -> Validation
  -> IO (Result ())
runValidation context awsCredentialBoundary validation =
  case validation of
    RequireLinux ->
      pure
        ( if os == "linux"
            then Success ()
            else Failure "This suite requires Linux."
        )
    RequireHostSubstrateSupported -> requireHostSubstrateSupported
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
    RequireSesSendingIdentityVerified -> requireSesSemanticReadiness AwsSesSendingReadiness
    RequireSesReceiveRuleSetActive -> requireSesSemanticReadiness AwsSesReceivingReadiness
    RequireSesReceiveBucketAccessible -> requireSesSemanticReadiness AwsSesCaptureReadiness
 where
  requireSettings :: IO (Result ())
  requireSettings = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    pure (either Failure (const (Success ())) settingsResult)

  requireHostSubstrateSupported :: IO (Result ())
  requireHostSubstrateSupported = do
    substrateResult <- detectHostSubstrate
    pure (either Failure (const (Success ())) substrateResult)

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
          Right () ->
            runAwsCredentialValidationWithRetry awsValidationRetryAttempts awsCredentialBoundary

  requireAwsIamHarnessReady :: IO (Result ())
  requireAwsIamHarnessReady = do
    configResult <- loadConfigFile (interpreterRepoRoot context)
    case configResult of
      Left err -> pure (Failure err)
      Right config ->
        case validateAwsBootstrapConfig config of
          Left err -> pure (Failure err)
          Right () -> do
            -- Sprint 7.16: the IAM harness's admin credential is the EPHEMERAL
            -- credential acquired from test-secrets.dhall's
            -- aws_admin_for_test_simulation block (harness simulating the
            -- prompt) or an interactive TTY prompt; it is never read from
            -- prodbox.dhall or Vault.
            credentialsResult <- acquireAdminAwsCredentials (interpreterRepoRoot context)
            pure $
              case credentialsResult of
                Left err ->
                  Failure
                    ( "Native IAM validation requires an ephemeral admin AWS \
                      \credential (from test-secrets.dhall's \
                      \aws_admin_for_test_simulation block, or the interactive \
                      \prompt): "
                        ++ err
                    )
                Right credentials ->
                  if hasHarnessAdminCredentials credentials
                    then Success ()
                    else
                      Failure
                        "Native IAM validation requires the acquired admin AWS credential to have a non-empty access key id, secret access key, and region."

  requireRoute53Access :: IO (Result ())
  requireRoute53Access = do
    settingsResult <- validateAndLoadSettings (interpreterRepoRoot context)
    case settingsResult of
      Left err -> pure (Failure err)
      Right settings -> do
        let zoneId = zone_id (route53 (validatedConfig settings))
        result <-
          dispatchHostProviderIntentFresh
            LifecycleAuthorityOperator
            (interpreterRepoRoot context)
            (Text.pack "prerequisite-route53-readiness")
            (ObserveProviderReadiness (ProviderReadinessRoute53Zone zoneId))
        pure $ case result of
          Left err -> Failure (renderProviderCallerError err)
          Right _ -> Success ()

  requireRoute53LifecycleCapability :: IO (Result ())
  requireRoute53LifecycleCapability = do
    exitCode <- ensureAwsSesStackResources (interpreterRepoRoot context)
    pure $ case exitCode of
      ExitSuccess -> Success ()
      ExitFailure code ->
        Failure ("Route 53 Provider reconciliation exited with code " ++ show code)

  requirePulumiLogin :: IO (Result ())
  requirePulumiLogin = do
    portForwardResult <-
      withMinioPortForward $ \endpoint -> do
        let localPort = hostDirectEndpointPort endpoint
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

  -- Sprint 8.10: deferred SES prerequisites are one-shot, read-only semantic
  -- observations.  Reconciliation already ran in the visible retained-SES
  -- preparation transaction; this boundary never creates or repairs AWS
  -- state and never accepts command exit success as readiness by itself.
  requireSesSemanticReadiness :: AwsSesReadinessScope -> IO (Result ())
  requireSesSemanticReadiness _scope = do
    exitCode <- ensureAwsSesStackResources (interpreterRepoRoot context)
    pure $ case exitCode of
      ExitSuccess -> Success ()
      ExitFailure code ->
        Failure ("SES Provider reconciliation exited with code " ++ show code)

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

echoProcessOutput :: ProcessOutput -> IO ()
echoProcessOutput output = do
  writeOutput (processStdout output)
  writeDiagnostic (processStderr output)

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
