{-# LANGUAGE OverloadedStrings #-}

module Prodbox.SupportedRuntime
    ( SupportedRuntimeContext (..),
      ensureOperationalAwsCredentialsFromAdminHarness,
      ensureOperationalAwsIdentityForSupportedRuntime,
      removeDeletePendingAwsResources,
      removeFqdnFromHostsText,
      removePublicHostHostsOverride,
    )
where

import Control.Concurrent (threadDelay)
import Control.Exception
    ( IOException,
      displayException,
      try,
    )
import Data.Aeson
    ( Value (..),
      eitherDecode,
      encode,
    )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BL
import Data.Char
    ( chr,
      digitToInt,
      isHexDigit,
    )
import Data.List
    ( intercalate,
      isInfixOf,
    )
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Vector as Vector
import Prodbox.Aws
    ( buildIamPolicyJson,
    )
import Prodbox.CLI.Command
    ( PolicyTier (PolicyFull),
    )
import Prodbox.Result
    ( Result (..),
    )
import Prodbox.Settings
    ( AcmeSection (..),
      ConfigFile (..),
      Credentials (..),
      DeploymentSection (..),
      DomainSection (..),
      Route53Section (..),
      StorageSection (..),
      ValidatedSettings (..),
      validateAndLoadSettings,
    )
import Prodbox.Subprocess
    ( CommandSpec (..),
      ProcessOutput (..),
      captureCommand,
    )
import System.Directory
    ( Permissions,
      createDirectoryIfMissing,
      getPermissions,
      removeFile,
      writable,
    )
import System.Exit
    ( ExitCode (..),
    )
import System.FilePath ((</>))
import System.IO
    ( hClose,
      openTempFile,
    )
import System.Process
    ( proc,
      readCreateProcessWithExitCode,
    )

prodboxIamUserName :: String
prodboxIamUserName = "prodbox"

prodboxIamInlinePolicyName :: String
prodboxIamInlinePolicyName = "prodbox-inline"

supportedRuntimePulumiStack :: String
supportedRuntimePulumiStack = "home"

homeStackAwsProviderUrn :: String
homeStackAwsProviderUrn = "urn:pulumi:home::prodbox::pulumi:providers:aws::aws-provider"

homeStackDemoRecordUrn :: String
homeStackDemoRecordUrn = "urn:pulumi:home::prodbox::aws:route53/record:Record::demo-a-record"

operationalCredentialReadyAttempts :: Int
operationalCredentialReadyAttempts = 30

operationalCredentialReadyDelayMicroseconds :: Int
operationalCredentialReadyDelayMicroseconds = 2000000

data SupportedRuntimeContext = SupportedRuntimeContext
    { supportedRuntimeRepoRoot :: FilePath,
      supportedRuntimeHelperEnvironment :: [(String, String)]
    }

ensureOperationalAwsCredentialsFromAdminHarness :: SupportedRuntimeContext -> IO (Either String String)
ensureOperationalAwsCredentialsFromAdminHarness context = do
    settingsResult <- loadValidatedSettings context
    case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
            credentialsValidResult <- operationalAwsCredentialsAreValid context settings
            case credentialsValidResult of
                Left err -> pure (Left err)
                Right credentialsValid ->
                    if not credentialsValid
                        then restoreOperationalAwsIdentityFromAdminHarness context settings
                        else do
                            policyCurrentResult <- operationalAwsPolicyIsCurrent context settings
                            case policyCurrentResult of
                                Left err -> pure (Left err)
                                Right True -> pure (Right "Operational AWS credentials and IAM policy already valid")
                                Right False -> restoreOperationalAwsIdentityFromAdminHarness context settings

ensureOperationalAwsIdentityForSupportedRuntime :: SupportedRuntimeContext -> IO (Either String String)
ensureOperationalAwsIdentityForSupportedRuntime context = do
    credentialResult <- ensureOperationalAwsCredentialsFromAdminHarness context
    case credentialResult of
        Left err -> pure (Left err)
        Right credentialSummary -> do
            currentSettingsResult <- loadValidatedSettings context
            case currentSettingsResult of
                Left err -> pure (Left err)
                Right currentSettings -> do
                    pulumiRepairResult <- repairPulumiStackAfterOperationalAwsRotation context currentSettings
                    pure $ do
                        pulumiSummary <- pulumiRepairResult
                        Right (credentialSummary ++ "; " ++ pulumiSummary)

removePublicHostHostsOverride :: SupportedRuntimeContext -> IO (Either String String)
removePublicHostHostsOverride context = do
    settingsResult <- loadValidatedSettings context
    case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
            let fqdn = preferredPublicHostFqdn (validatedConfig settings)
                hostsPath = "/etc/hosts"
            originalTextResult <- try (readFile hostsPath) :: IO (Either IOException String)
            case originalTextResult of
                Left err -> pure (Left ("failed to read " ++ hostsPath ++ ": " ++ displayException err))
                Right originalText -> do
                    let (updatedText, removedEntries) = removeFqdnFromHostsText originalText fqdn
                    if removedEntries == 0
                        then pure (Right ("No /etc/hosts override found for " ++ fqdn))
                        else do
                            writeResult <- writeHostsFile context hostsPath updatedText
                            case writeResult of
                                Left err -> pure (Left err)
                                Right () -> do
                                    postWriteResult <- try (readFile hostsPath) :: IO (Either IOException String)
                                    case postWriteResult of
                                        Left err -> pure (Left ("failed to re-read " ++ hostsPath ++ ": " ++ displayException err))
                                        Right postWriteText -> do
                                            let (_, remainingEntries) = removeFqdnFromHostsText postWriteText fqdn
                                            if remainingEntries == 0
                                                then pure (Right ("Removed " ++ show removedEntries ++ " /etc/hosts override entrie(s) for " ++ fqdn))
                                                else pure (Left (hostsPath ++ " still contains unsupported override for " ++ fqdn))

removeFqdnFromHostsText :: String -> String -> (String, Int)
removeFqdnFromHostsText hostsText fqdn =
    case map toLowerAscii (trimSpaces fqdn) of
        "" -> (hostsText, 0)
        target ->
            let (updatedLines, removedEntries) = foldr (collectLine target) ([], 0) (lines hostsText)
             in (renderHostsText updatedLines (endsWithNewline hostsText), removedEntries)
  where
    collectLine :: String -> String -> ([String], Int) -> ([String], Int)
    collectLine target rawLine (updatedLines, removedEntries) =
        let (body, commentPart) = splitComment rawLine
            tokens = words body
         in case tokens of
                [] -> (rawLine : updatedLines, removedEntries)
                [_] -> (rawLine : updatedLines, removedEntries)
                ipAddress : names ->
                    let keptNames = filter ((/= target) . map toLowerAscii) names
                        removedHere = length names - length keptNames
                     in if removedHere == 0
                            then (rawLine : updatedLines, removedEntries)
                            else
                                case keptNames of
                                    [] ->
                                        case trimSpaces commentPart of
                                            "" -> (updatedLines, removedEntries + removedHere)
                                            strippedComment -> (("# " ++ strippedComment) : updatedLines, removedEntries + removedHere)
                                    _ ->
                                        let rebuilt = ipAddress ++ " " ++ unwords keptNames
                                            rendered =
                                                case trimSpaces commentPart of
                                                    "" -> rebuilt
                                                    strippedComment -> rebuilt ++ "  # " ++ strippedComment
                                         in (rendered : updatedLines, removedEntries + removedHere)

removeDeletePendingAwsResources :: Value -> Either String (Value, Int)
removeDeletePendingAwsResources exportedValue =
    case exportedValue of
        Object rootObject ->
            case KeyMap.lookup (Key.fromString "deployment") rootObject of
                Just (Object deploymentObject) ->
                    case KeyMap.lookup (Key.fromString "resources") deploymentObject of
                        Just (Array resources) ->
                            let (keptResources, removedCount) = Vector.foldr collectResource ([], 0) resources
                                updatedDeployment =
                                    Object
                                        ( KeyMap.insert
                                            (Key.fromString "resources")
                                            (Array (Vector.fromList (reverse keptResources)))
                                            deploymentObject
                                        )
                                updatedRoot =
                                    Object
                                        (KeyMap.insert (Key.fromString "deployment") updatedDeployment rootObject)
                             in Right (updatedRoot, removedCount)
                        _ -> Left unexpectedPulumiExportShape
                _ -> Left unexpectedPulumiExportShape
        _ -> Left unexpectedPulumiExportShape
  where
    collectResource :: Value -> ([Value], Int) -> ([Value], Int)
    collectResource value (keptResources, removedCount) =
        case value of
            Object resourceObject
                | isDeletePendingAwsResource resourceObject -> (keptResources, removedCount + 1)
            _ -> (value : keptResources, removedCount)

unexpectedPulumiExportShape :: String
unexpectedPulumiExportShape = "pulumi stack export returned deployment resources in an unexpected shape"

loadValidatedSettings :: SupportedRuntimeContext -> IO (Either String ValidatedSettings)
loadValidatedSettings context = validateAndLoadSettings (supportedRuntimeRepoRoot context)

preferredPublicHostFqdn :: ConfigFile -> String
preferredPublicHostFqdn config =
    case vscode_fqdn (domain config) of
        Just value -> Text.unpack value
        Nothing -> Text.unpack (demo_fqdn (domain config))

operationalAwsCredentialsAreValid :: SupportedRuntimeContext -> ValidatedSettings -> IO (Either String Bool)
operationalAwsCredentialsAreValid context settings = do
    outputResult <-
        captureCommand
            CommandSpec
                { commandPath = "aws",
                  commandArguments = ["sts", "get-caller-identity", "--output", "json"],
                  commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) (aws (validatedConfig settings))),
                  commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                }
    pure $
        case outputResult of
            Failure err -> Left ("failed to start `aws sts get-caller-identity --output json`: " ++ err)
            Success output -> Right (processExitCode output == ExitSuccess)

operationalAwsPolicyIsCurrent :: SupportedRuntimeContext -> ValidatedSettings -> IO (Either String Bool)
operationalAwsPolicyIsCurrent context settings =
    case requireAdminCredentials (aws_admin (validatedConfig settings)) of
        Nothing -> pure (Right True)
        Just adminCredentials -> do
            policyResult <-
                captureCommand
                    CommandSpec
                        { commandPath = "aws",
                          commandArguments =
                            [ "iam",
                              "get-user-policy",
                              "--user-name",
                              prodboxIamUserName,
                              "--policy-name",
                              prodboxIamInlinePolicyName
                            ],
                          commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) adminCredentials),
                          commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                        }
            case policyResult of
                Failure err -> pure (Left ("failed to start `aws iam get-user-policy`: " ++ err))
                Success output ->
                    case processExitCode output of
                        ExitSuccess -> do
                            expectedPolicyResult <- expectedFullPolicyValue context
                            pure $ do
                                expectedPolicy <- expectedPolicyResult
                                currentPolicy <- decodeAwsPolicyDocument (processStdout output)
                                Right (currentPolicy == expectedPolicy)
                        ExitFailure _ ->
                            let detail = commandOutputDetail output
                             in if "NoSuchEntity" `isInfixOf` detail
                                    then pure (Right False)
                                    else pure (Left ("aws iam get-user-policy failed: " ++ detail))

restoreOperationalAwsIdentityFromAdminHarness :: SupportedRuntimeContext -> ValidatedSettings -> IO (Either String String)
restoreOperationalAwsIdentityFromAdminHarness context settings =
    case requireAdminCredentials (aws_admin (validatedConfig settings)) of
        Nothing ->
            pure
                ( Left
                    "Operational AWS credentials are unavailable and the repository-root aws_admin config is incomplete. Populate aws_admin.access_key_id, aws_admin.secret_access_key, and aws_admin.region to allow automatic recovery."
                )
        Just adminCredentials -> do
            expectedPolicyJsonResult <- expectedFullPolicyJson context
            case expectedPolicyJsonResult of
                Left err -> pure (Left err)
                Right expectedPolicyJson -> do
                    createUserResult <-
                        captureCommand
                            CommandSpec
                                { commandPath = "aws",
                                  commandArguments = ["iam", "create-user", "--user-name", prodboxIamUserName],
                                  commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) adminCredentials),
                                  commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                                }
                    case createUserResult of
                        Failure err -> pure (Left ("failed to start `aws iam create-user`: " ++ err))
                        Success output ->
                            case processExitCode output of
                                ExitSuccess -> finishRestore adminCredentials expectedPolicyJson
                                ExitFailure _ ->
                                    let detail = commandOutputDetail output
                                     in if "EntityAlreadyExists" `isInfixOf` detail
                                            then finishRestore adminCredentials expectedPolicyJson
                                            else pure (Left ("aws iam create-user failed: " ++ detail))
  where
    finishRestore adminCredentials expectedPolicyJson = do
        listKeysResult <-
            captureCommand
                CommandSpec
                    { commandPath = "aws",
                      commandArguments = ["iam", "list-access-keys", "--user-name", prodboxIamUserName],
                      commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) adminCredentials),
                      commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                    }
        pure $ do
            listKeysValue <- requireSuccessfulJsonOutput "aws iam list-access-keys" listKeysResult
            accessKeyIds <- accessKeyIdsFromListPayload listKeysValue
            Right accessKeyIds
        >>= \accessKeyIdsResult ->
            case accessKeyIdsResult of
                Left err -> pure (Left err)
                Right accessKeyIds -> do
                    deleteResult <- deleteAccessKeys context adminCredentials accessKeyIds
                    case deleteResult of
                        Left err -> pure (Left err)
                        Right () -> do
                            putPolicyResult <-
                                captureCommand
                                    CommandSpec
                                        { commandPath = "aws",
                                          commandArguments =
                                            [ "iam",
                                              "put-user-policy",
                                              "--user-name",
                                              prodboxIamUserName,
                                              "--policy-name",
                                              prodboxIamInlinePolicyName,
                                              "--policy-document",
                                              expectedPolicyJson
                                            ],
                                          commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) adminCredentials),
                                          commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                                        }
                            case requireSuccessfulCommand "aws iam put-user-policy" putPolicyResult of
                                Left err -> pure (Left err)
                                Right () -> do
                                    createKeyResult <-
                                        captureCommand
                                            CommandSpec
                                                { commandPath = "aws",
                                                  commandArguments = ["iam", "create-access-key", "--user-name", prodboxIamUserName],
                                                  commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) adminCredentials),
                                                  commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                                                }
                                    case requireSuccessfulJsonOutput "aws iam create-access-key" createKeyResult of
                                        Left err -> pure (Left err)
                                        Right createKeyValue ->
                                            case createdAccessKeyCredentials createKeyValue of
                                                Left err -> pure (Left err)
                                                Right (newAccessKeyId, newSecretAccessKey) -> do
                                                    writeConfigResult <-
                                                        writeOperationalCredentialsToConfig
                                                            context
                                                            settings
                                                            newAccessKeyId
                                                            newSecretAccessKey
                                                            adminCredentials
                                                    case writeConfigResult of
                                                        Left err -> pure (Left err)
                                                        Right () -> do
                                                            readyResult <-
                                                                waitForOperationalCredentialsReady
                                                                    context
                                                                    newAccessKeyId
                                                                    newSecretAccessKey
                                                                    adminCredentials
                                                            case readyResult of
                                                                Left err -> pure (Left err)
                                                                Right () -> pure (Right "Restored operational AWS IAM user prodbox with full policy tier")

deleteAccessKeys :: SupportedRuntimeContext -> Credentials -> [String] -> IO (Either String ())
deleteAccessKeys context adminCredentials accessKeyIds = go accessKeyIds
  where
    go [] = pure (Right ())
    go (accessKeyId : remaining) = do
        deleteResult <-
            captureCommand
                CommandSpec
                    { commandPath = "aws",
                      commandArguments =
                        [ "iam",
                          "delete-access-key",
                          "--user-name",
                          prodboxIamUserName,
                          "--access-key-id",
                          accessKeyId
                        ],
                      commandEnvironment = Just (awsCliEnvironment (supportedRuntimeHelperEnvironment context) adminCredentials),
                      commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                    }
        case requireSuccessfulCommand ("aws iam delete-access-key " ++ accessKeyId) deleteResult of
            Left err -> pure (Left err)
            Right () -> go remaining

writeOperationalCredentialsToConfig ::
    SupportedRuntimeContext ->
    ValidatedSettings ->
    String ->
    String ->
    Credentials ->
    IO (Either String ())
writeOperationalCredentialsToConfig context settings newAccessKeyId newSecretAccessKey adminCredentials = do
    let currentConfig = validatedConfig settings
        updatedConfig =
            currentConfig
                { aws =
                    (aws currentConfig)
                        { access_key_id = Text.pack newAccessKeyId,
                          secret_access_key = Text.pack newSecretAccessKey,
                          session_token = Nothing,
                          region = region adminCredentials
                        }
                }
        dhallPath = supportedRuntimeRepoRoot context </> "prodbox-config.dhall"
    writeResult <- try (writeFile dhallPath (renderConfigDhall updatedConfig)) :: IO (Either IOException ())
    case writeResult of
        Left err -> pure (Left ("failed to write " ++ dhallPath ++ ": " ++ displayException err))
        Right () -> do
            validationResult <- validateAndLoadSettings (supportedRuntimeRepoRoot context)
            pure $
                case validationResult of
                    Left err -> Left err
                    Right _ -> Right ()

waitForOperationalCredentialsReady ::
    SupportedRuntimeContext ->
    String ->
    String ->
    Credentials ->
    IO (Either String ())
waitForOperationalCredentialsReady context newAccessKeyId newSecretAccessKey adminCredentials =
    go operationalCredentialReadyAttempts "STS validation did not return a result"
  where
    env =
        awsCliEnvironment
            (supportedRuntimeHelperEnvironment context)
            Credentials
                { access_key_id = Text.pack newAccessKeyId,
                  secret_access_key = Text.pack newSecretAccessKey,
                  session_token = Nothing,
                  region = region adminCredentials
                }

    go :: Int -> String -> IO (Either String ())
    go 0 lastError =
        pure
            ( Left
                ( "Generated operational AWS credentials failed validation via `aws sts get-caller-identity`: "
                    ++ lastError
                )
            )
    go attemptsRemaining lastError = do
        outputResult <-
            captureCommand
                CommandSpec
                    { commandPath = "aws",
                      commandArguments = ["sts", "get-caller-identity", "--output", "json"],
                      commandEnvironment = Just env,
                      commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                    }
        case outputResult of
            Failure err -> pure (Left ("failed to start `aws sts get-caller-identity --output json`: " ++ err))
            Success output ->
                case processExitCode output of
                    ExitSuccess -> pure (Right ())
                    ExitFailure _ -> do
                        threadDelay operationalCredentialReadyDelayMicroseconds
                        let detail = commandOutputDetail output
                            nextError = if detail == "" then lastError else detail
                        go (attemptsRemaining - 1) nextError

repairPulumiStackAfterOperationalAwsRotation ::
    SupportedRuntimeContext ->
    ValidatedSettings ->
    IO (Either String String)
repairPulumiStackAfterOperationalAwsRotation context settings = do
    pulumiEnvResult <- supportedRuntimePulumiEnvironment context settings
    case pulumiEnvResult of
        Left err -> pure (Left err)
        Right pulumiEnv -> do
            stackSelectResult <- ensureSupportedRuntimePulumiStackSelected context pulumiEnv
            case stackSelectResult of
                Left err -> pure (Left err)
                Right () -> do
                    let targetArgs =
                            [ "up",
                              "--yes",
                              "--stack",
                              supportedRuntimePulumiStack,
                              "--target",
                              homeStackAwsProviderUrn,
                              "--target",
                              homeStackDemoRecordUrn
                            ]
                    firstUpResult <- runRawPulumiCommand context pulumiEnv targetArgs
                    case firstUpResult of
                        Left err -> pure (Left err)
                        Right firstUp ->
                            case processExitCode firstUp of
                                ExitSuccess -> pure (Right "Pulumi stack updated to the current operational AWS credentials")
                                ExitFailure _ ->
                                    let detail = commandOutputDetail firstUp
                                     in if "InvalidClientTokenId" `isInfixOf` detail
                                            then do
                                                repairResult <- repairDeletePendingAwsPulumiState context pulumiEnv
                                                case repairResult of
                                                    Left err -> pure (Left err)
                                                    Right repairSummary -> do
                                                        secondUpResult <- runRawPulumiCommand context pulumiEnv targetArgs
                                                        pure $ do
                                                            secondUp <- secondUpResult
                                                            case processExitCode secondUp of
                                                                ExitSuccess -> Right (repairSummary ++ "; Pulumi stack updated to the current operational AWS credentials")
                                                                ExitFailure _ -> Left ("pulumi up still failed after repairing stale AWS provider state: " ++ commandOutputDetail secondUp)
                                            else pure (Left ("pulumi up failed after AWS restore: " ++ detail))

supportedRuntimePulumiEnvironment ::
    SupportedRuntimeContext ->
    ValidatedSettings ->
    IO (Either String [(String, String)])
supportedRuntimePulumiEnvironment context settings = do
    let repoRoot = supportedRuntimeRepoRoot context
        backendDir = repoRoot </> ".pulumi-backend"
        baseEnvironment = awsCliEnvironment (supportedRuntimeHelperEnvironment context) (aws (validatedConfig settings))
    createDirectoryIfMissing True backendDir
    let withBackend =
            case lookup "PULUMI_BACKEND_URL" baseEnvironment of
                Nothing -> upsertEnv "PULUMI_BACKEND_URL" ("file://" ++ backendDir) baseEnvironment
                Just _ -> baseEnvironment
        withPassphrase =
            case lookup "PULUMI_CONFIG_PASSPHRASE" withBackend of
                Just _ -> withBackend
                Nothing ->
                    case lookup "PULUMI_CONFIG_PASSPHRASE_FILE" withBackend of
                        Just _ -> withBackend
                        Nothing -> upsertEnv "PULUMI_CONFIG_PASSPHRASE" "" withBackend
    pure (Right withPassphrase)

ensureSupportedRuntimePulumiStackSelected ::
    SupportedRuntimeContext ->
    [(String, String)] ->
    IO (Either String ())
ensureSupportedRuntimePulumiStackSelected context pulumiEnvironment = do
    selectedResult <-
        runRawPulumiCommand
            context
            pulumiEnvironment
            ["stack", "select", supportedRuntimePulumiStack, "--create"]
    pure $ do
        output <- selectedResult
        case processExitCode output of
            ExitSuccess -> Right ()
            ExitFailure _ ->
                Left
                    ( "pulumi stack select failed for "
                        ++ supportedRuntimePulumiStack
                        ++ ": "
                        ++ commandOutputDetail output
                    )

repairDeletePendingAwsPulumiState ::
    SupportedRuntimeContext ->
    [(String, String)] ->
    IO (Either String String)
repairDeletePendingAwsPulumiState context pulumiEnvironment = do
    exportResult <-
        runRawPulumiCommand
            context
            pulumiEnvironment
            ["stack", "export", "--stack", supportedRuntimePulumiStack]
    case exportResult of
        Left err -> pure (Left err)
        Right output ->
            case processExitCode output of
                ExitFailure _ -> pure (Left ("pulumi stack export failed: " ++ commandOutputDetail output))
                ExitSuccess ->
                    case eitherDecode (BL.fromStrict (TextEncoding.encodeUtf8 (Text.pack (processStdout output)))) of
                        Left err -> pure (Left ("pulumi stack export returned invalid JSON: " ++ err))
                        Right exportedValue ->
                            case removeDeletePendingAwsResources exportedValue of
                                Left err -> pure (Left err)
                                Right (_, 0) -> pure (Right "No stale delete-pending AWS Pulumi resources required repair")
                                Right (updatedValue, removedCount) -> do
                                    (tempPath, writeTempResult) <- writeTemporaryPulumiImport context updatedValue
                                    case writeTempResult of
                                        Left err -> pure (Left err)
                                        Right () -> do
                                            importResult <-
                                                runRawPulumiCommand
                                                    context
                                                    pulumiEnvironment
                                                    [ "stack",
                                                      "import",
                                                      "--stack",
                                                      supportedRuntimePulumiStack,
                                                      "--file",
                                                      tempPath
                                                    ]
                                            _ <- try (removeFile tempPath) :: IO (Either IOException ())
                                            pure $ do
                                                importOutput <- importResult
                                                case processExitCode importOutput of
                                                    ExitSuccess -> Right ("Removed " ++ show removedCount ++ " stale delete-pending AWS Pulumi state resources")
                                                    ExitFailure _ -> Left ("pulumi stack import failed: " ++ commandOutputDetail importOutput)

writeTemporaryPulumiImport :: SupportedRuntimeContext -> Value -> IO (FilePath, Either String ())
writeTemporaryPulumiImport context exportedValue = do
    (tempPath, handle) <- openTempFile (supportedRuntimeRepoRoot context) "pulumi-supported-runtime-import.json"
    hClose handle
    writeResult <- try (BL.writeFile tempPath (encode exportedValue)) :: IO (Either IOException ())
    pure
        ( tempPath,
          case writeResult of
            Left err -> Left ("failed to write temporary Pulumi import file: " ++ displayException err)
            Right () -> Right ()
        )

runRawPulumiCommand ::
    SupportedRuntimeContext ->
    [(String, String)] ->
    [String] ->
    IO (Either String ProcessOutput)
runRawPulumiCommand context pulumiEnvironment pulumiArguments = do
    outputResult <-
        captureCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = pulumiArguments,
                  commandEnvironment = Just pulumiEnvironment,
                  commandWorkingDirectory = Just (supportedRuntimeRepoRoot context)
                }
    pure $
        case outputResult of
            Failure err -> Left ("failed to start `" ++ unwords ("pulumi" : pulumiArguments) ++ "`: " ++ err)
            Success output -> Right output

writeHostsFile :: SupportedRuntimeContext -> FilePath -> String -> IO (Either String ())
writeHostsFile _context hostsPath updatedText = do
    permissionsResult <- try (getPermissions hostsPath) :: IO (Either IOException Permissions)
    case permissionsResult of
        Left err -> pure (Left ("failed to read permissions for " ++ hostsPath ++ ": " ++ displayException err))
        Right permissions ->
            if writable permissions
                then do
                    writeResult <- try (writeFile hostsPath updatedText) :: IO (Either IOException ())
                    pure $
                        case writeResult of
                            Left err -> Left ("failed to rewrite " ++ hostsPath ++ ": " ++ displayException err)
                            Right () -> Right ()
                else do
                    sudoResult <-
                        try
                            ( readCreateProcessWithExitCode
                                (proc "sudo" ["tee", hostsPath])
                                updatedText
                            ) :: IO (Either IOException (ExitCode, String, String))
                    pure $
                        case sudoResult of
                            Left err -> Left ("failed to rewrite " ++ hostsPath ++ ": " ++ displayException err)
                            Right (exitCode, stdoutText, stderrText) ->
                                case exitCode of
                                    ExitSuccess -> Right ()
                                    ExitFailure code ->
                                        Left
                                            ( "failed to rewrite "
                                                ++ hostsPath
                                                ++ ": exit code "
                                                ++ show code
                                                ++ suffixFromTexts stdoutText stderrText
                                            )

expectedFullPolicyJson :: SupportedRuntimeContext -> IO (Either String String)
expectedFullPolicyJson _context =
    pure (Right (trimTrailingNewlines (buildIamPolicyJson PolicyFull)))

expectedFullPolicyValue :: SupportedRuntimeContext -> IO (Either String Value)
expectedFullPolicyValue context = do
    policyJsonResult <- expectedFullPolicyJson context
    pure $ do
        policyJson <- policyJsonResult
        eitherDecode (BL.fromStrict (TextEncoding.encodeUtf8 (Text.pack policyJson)))

requireSuccessfulCommand :: String -> Result ProcessOutput -> Either String ()
requireSuccessfulCommand commandLabel commandResult =
    case commandResult of
        Failure err -> Left ("failed to start `" ++ commandLabel ++ "`: " ++ err)
        Success output ->
            case processExitCode output of
                ExitSuccess -> Right ()
                ExitFailure _ -> Left (commandLabel ++ " failed: " ++ commandOutputDetail output)

requireSuccessfulJsonOutput :: String -> Result ProcessOutput -> Either String Value
requireSuccessfulJsonOutput commandLabel commandResult =
    case commandResult of
        Failure err -> Left ("failed to start `" ++ commandLabel ++ "`: " ++ err)
        Success output ->
            case processExitCode output of
                ExitSuccess -> eitherDecode (BL.fromStrict (TextEncoding.encodeUtf8 (Text.pack (processStdout output))))
                ExitFailure _ -> Left (commandLabel ++ " failed: " ++ commandOutputDetail output)

accessKeyIdsFromListPayload :: Value -> Either String [String]
accessKeyIdsFromListPayload value = do
    metadataValue <- objectField value "AccessKeyMetadata" "list-access-keys"
    case metadataValue of
        Array accessKeys -> mapM accessKeyIdFromMetadata (Vector.toList accessKeys)
        _ -> Left "list-access-keys returned AccessKeyMetadata in an unexpected shape"
  where
    accessKeyIdFromMetadata metadataValue = stringField metadataValue "AccessKeyId" "AccessKeyMetadata"

createdAccessKeyCredentials :: Value -> Either String (String, String)
createdAccessKeyCredentials value = do
    accessKeyValue <- objectField value "AccessKey" "create-access-key"
    accessKeyId <- stringField accessKeyValue "AccessKeyId" "AccessKey"
    secretKey <- stringField accessKeyValue "SecretAccessKey" "AccessKey"
    Right (accessKeyId, secretKey)

decodeAwsPolicyDocument :: String -> Either String Value
decodeAwsPolicyDocument stdoutText = do
    responseValue <- eitherDecode (BL.fromStrict (TextEncoding.encodeUtf8 (Text.pack stdoutText)))
    policyDocumentValue <- objectField responseValue "PolicyDocument" "get-user-policy"
    case policyDocumentValue of
        Object _ -> Right policyDocumentValue
        String encodedDocument ->
            eitherDecode
                ( BL.fromStrict
                    (TextEncoding.encodeUtf8 (Text.pack (decodePercentEscapes (Text.unpack encodedDocument))))
                )
        _ -> Left "aws iam get-user-policy returned an unexpected PolicyDocument"

objectField :: Value -> String -> String -> Either String Value
objectField value fieldName context =
    case value of
        Object objectValue ->
            case KeyMap.lookup (Key.fromString fieldName) objectValue of
                Just fieldValue -> Right fieldValue
                Nothing -> Left (context ++ " did not include required field `" ++ fieldName ++ "`")
        _ -> Left (context ++ " returned an unexpected JSON shape")

stringField :: Value -> String -> String -> Either String String
stringField value fieldName context = do
    fieldValue <- objectField value fieldName context
    case fieldValue of
        String textValue -> Right (Text.unpack textValue)
        _ -> Left (context ++ " did not include text field `" ++ fieldName ++ "`")

requireAdminCredentials :: Credentials -> Maybe Credentials
requireAdminCredentials credentials =
    case
        ( trimmedCredentialField (access_key_id credentials),
          trimmedCredentialField (secret_access_key credentials),
          trimmedCredentialField (region credentials)
        ) of
        (Just accessKeyId, Just secretAccessKey, Just regionText) ->
            Just
                credentials
                    { access_key_id = accessKeyId,
                      secret_access_key = secretAccessKey,
                      session_token = fmap Text.strip (session_token credentials),
                      region = regionText
                    }
        _ -> Nothing

trimmedCredentialField :: Text.Text -> Maybe Text.Text
trimmedCredentialField value =
    case Text.strip value of
        "" -> Nothing
        trimmedValue -> Just trimmedValue

awsCliEnvironment :: [(String, String)] -> Credentials -> [(String, String)]
awsCliEnvironment baseEnvironment credentials =
    upsertEnv "AWS_REGION" (Text.unpack (region credentials))
        $ upsertEnv "AWS_DEFAULT_REGION" (Text.unpack (region credentials))
        $ maybe
            (removeEnv "AWS_SESSION_TOKEN")
            (\token -> upsertEnv "AWS_SESSION_TOKEN" (Text.unpack token))
            (session_token credentials)
        $ upsertEnv "AWS_SECRET_ACCESS_KEY" (Text.unpack (secret_access_key credentials))
        $ upsertEnv "AWS_ACCESS_KEY_ID" (Text.unpack (access_key_id credentials))
        $ baseEnvironment

renderConfigDhall :: ConfigFile -> String
renderConfigDhall config =
    unlines
        [ "let Config = ./prodbox-config-types.dhall",
          "",
          "in  Config::{",
          "    , aws = Config.default.aws // {",
          "        , access_key_id = " ++ dhallText (access_key_id (aws config)),
          "        , secret_access_key = " ++ dhallText (secret_access_key (aws config)),
          "        , session_token = " ++ dhallOptionalText (session_token (aws config)),
          "        , region = " ++ dhallText (region (aws config)),
          "        }",
          "    , aws_admin = Config.default.aws_admin // {",
          "        , access_key_id = " ++ dhallText (access_key_id (aws_admin config)),
          "        , secret_access_key = " ++ dhallText (secret_access_key (aws_admin config)),
          "        , session_token = " ++ dhallOptionalText (session_token (aws_admin config)),
          "        , region = " ++ dhallText (region (aws_admin config)),
          "        }",
          "    , route53 = { zone_id = " ++ dhallText (zone_id (route53 config)) ++ " }",
          "    , domain = Config.default.domain // {",
          "        , demo_fqdn = " ++ dhallText (demo_fqdn (domain config)),
          "        , demo_ttl = " ++ show (demo_ttl (domain config)),
          "        , vscode_fqdn = " ++ dhallOptionalText (vscode_fqdn (domain config)),
          "        }",
          "    , acme = Config.default.acme // {",
          "        , email = " ++ dhallText (email (acme config)),
          "        , server = " ++ dhallText (server (acme config)),
          "        , eab_key_id = " ++ dhallOptionalText (eab_key_id (acme config)),
          "        , eab_hmac_key = " ++ dhallOptionalText (eab_hmac_key (acme config)),
          "        }",
          "    , deployment = Config.default.deployment // {",
          "        , dev_mode = " ++ dhallBool (dev_mode (deployment config)),
          "        , bootstrap_public_ip_override = " ++ dhallOptionalText (bootstrap_public_ip_override (deployment config)),
          "        , pulumi_enable_dns_bootstrap = " ++ dhallBool (pulumi_enable_dns_bootstrap (deployment config)),
          "        }",
          "    , storage = Config.default.storage // {",
          "        , manual_pv_host_root = " ++ dhallText (manual_pv_host_root (storage config)),
          "        }",
          "    }",
          ""
        ]

dhallText :: Text.Text -> String
dhallText = show . Text.unpack

dhallOptionalText :: Maybe Text.Text -> String
dhallOptionalText maybeValue =
    case maybeValue of
        Nothing -> "None Text"
        Just value -> "Some " ++ dhallText value

dhallBool :: Bool -> String
dhallBool True = "True"
dhallBool False = "False"

isDeletePendingAwsResource :: KeyMap.KeyMap Value -> Bool
isDeletePendingAwsResource resourceObject =
    case (KeyMap.lookup (Key.fromString "delete") resourceObject, KeyMap.lookup (Key.fromString "type") resourceObject) of
        (Just (Bool True), Just (String resourceType)) ->
            resourceType == "pulumi:providers:aws" || "aws:" `Text.isPrefixOf` resourceType
        _ -> False

splitComment :: String -> (String, String)
splitComment rawLine =
    case break (== '#') rawLine of
        (body, []) -> (body, "")
        (body, _ : comment) -> (body, comment)

renderHostsText :: [String] -> Bool -> String
renderHostsText updatedLines hadTrailingNewline =
    case updatedLines of
        [] -> if hadTrailingNewline then "\n" else ""
        _ ->
            let rendered = unlines updatedLines
             in if hadTrailingNewline then rendered else trimTrailingNewlines rendered

endsWithNewline :: String -> Bool
endsWithNewline rawText = not (null rawText) && last rawText == '\n'

trimSpaces :: String -> String
trimSpaces = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse

trimTrailingNewlines :: String -> String
trimTrailingNewlines = reverse . dropWhile (== '\n') . reverse

toLowerAscii :: Char -> Char
toLowerAscii character
    | 'A' <= character && character <= 'Z' = chr (fromEnum character + 32)
    | otherwise = character

decodePercentEscapes :: String -> String
decodePercentEscapes [] = []
decodePercentEscapes ('%' : first : second : remaining)
    | isHexDigit first && isHexDigit second =
        let value = digitToInt first * 16 + digitToInt second
         in chr value : decodePercentEscapes remaining
decodePercentEscapes (character : remaining) = character : decodePercentEscapes remaining

commandOutputDetail :: ProcessOutput -> String
commandOutputDetail output =
    case filter (/= "") [trimTrailingNewlines (processStderr output), trimTrailingNewlines (processStdout output)] of
        [] -> "exit code " ++ showExitCode (processExitCode output)
        rendered -> intercalate " | " rendered

suffixFromTexts :: String -> String -> String
suffixFromTexts stdoutText stderrText =
    case filter (/= "") [trimTrailingNewlines stderrText, trimTrailingNewlines stdoutText] of
        [] -> ""
        rendered -> ": " ++ intercalate " | " rendered

showExitCode :: ExitCode -> String
showExitCode exitCode =
    case exitCode of
        ExitSuccess -> "0"
        ExitFailure code -> show code

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv key value environment = (key, value) : filter ((/= key) . fst) environment

removeEnv :: String -> [(String, String)] -> [(String, String)]
removeEnv key = filter ((/= key) . fst)
