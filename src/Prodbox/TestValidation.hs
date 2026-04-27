{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestValidation (
    runNativeValidation,
    verifyAwsTestSshReachability,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (
    IOException,
    SomeException,
    displayException,
    try,
 )
import Control.Monad (foldM)
import Data.Aeson (
    Value (..),
    eitherDecode,
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiUpper)
import Data.List (isInfixOf, sort)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Prodbox.Aws (
    runAwsIamHarnessSetup,
    runAwsIamHarnessTeardown,
 )
import Prodbox.AwsEnvironment (
    overlayAwsCredentials,
 )
import Prodbox.BuildSupport (
    canonicalOperatorBinaryPath,
 )
import Prodbox.CLI.Command (
    PolicyTier (PolicyFull),
 )
import Prodbox.Dns (preferredPublicHostFqdn)
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
import Prodbox.Infra.AwsTestStack qualified as AwsTest
import Prodbox.Result (Result (..))
import Prodbox.Settings (
    Route53Section (..),
    ValidatedSettings (..),
    aws,
    route53,
    validateAndLoadSettings,
 )
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
    commandDisplay,
    runStreamingCommand,
 )
import Prodbox.TestPlan (
    NativeValidation (..),
    nativeValidationId,
 )
import System.Directory (removeFile)
import System.Environment (
    getEnvironment,
 )
import System.Exit (
    ExitCode (..),
 )
import System.IO (
    hClose,
    hPutStr,
    hPutStrLn,
    openTempFile,
    stderr,
 )

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

publicEdgeReadyAttempts :: Int
publicEdgeReadyAttempts = 30

publicEdgeReadyDelayMicroseconds :: Int
publicEdgeReadyDelayMicroseconds = 10000000

awsTestSshReadyAttempts :: Int
awsTestSshReadyAttempts = 18

awsTestSshReadyDelayMicroseconds :: Int
awsTestSshReadyDelayMicroseconds = 10000000

runNativeValidation :: FilePath -> [(String, String)] -> NativeValidation -> IO ExitCode
runNativeValidation repoRoot environment validation = do
    putStrLn ("Validation: " ++ nativeValidationId validation)
    case validation of
        ValidationChartsVscode -> runChartsVscodeValidation repoRoot
        ValidationPublicDns -> runPublicDnsValidation repoRoot
        ValidationDnsAws -> runDnsAwsValidation repoRoot
        ValidationAwsIam ->
            runSequentially
                [ assertProducedOutputContainsAll
                    "aws-iam harness setup --tier full"
                    (runAwsIamHarnessSetup repoRoot PolicyFull)
                    ["IAM_USER=prodbox", "POLICY_TIER=full"]
                , assertProducedOutputContainsAll
                    "aws-iam harness teardown"
                    (runAwsIamHarnessTeardown repoRoot)
                    ["IAM_USER=prodbox", "USER_DELETED="]
                , assertProducedOutputContainsAll
                    "aws-iam harness setup --tier full"
                    (runAwsIamHarnessSetup repoRoot PolicyFull)
                    ["IAM_USER=prodbox", "POLICY_TIER=full"]
                ]
        ValidationAwsEks ->
            runSequentially
                [ assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["pulumi", "eks-resources"]
                    ["STACK=" ++ AwsEks.awsEksTestStackName, "CLUSTER_NAME=", "NODE_GROUP_NAME="]
                , verifyAwsEksSnapshot repoRoot
                ]
        ValidationPulumi ->
            runSequentially
                [ assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["pulumi", "test-resources"]
                    ["STACK=" ++ AwsTest.awsTestStackName, "NODE_COUNT=3"]
                , verifyAwsTestSnapshot repoRoot
                ]
        ValidationHaRke2Aws ->
            runSequentially
                [ assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["pulumi", "test-resources"]
                    ["STACK=" ++ AwsTest.awsTestStackName, "NODE_COUNT=3"]
                , verifyAwsTestSnapshot repoRoot
                , verifyAwsTestSshReachability repoRoot
                ]
        ValidationGatewayDaemon -> runGatewayDaemonValidation repoRoot environment
        ValidationGatewayPods ->
            runSequentially
                [ runNativeCliCommandForExitCode repoRoot environment ["k8s", "wait", "--namespace", "prodbox"]
                , runNativeCliCommandForExitCode repoRoot environment ["k8s", "logs", "--namespace", "prodbox", "--tail", "20"]
                ]
        ValidationGatewayPartition -> runNativeCliCommandForExitCode repoRoot environment ["tla-check"]
        ValidationChartsPlatform ->
            runSequentially
                [ assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["charts", "list"]
                    ["CHART_LIST", "NAME=vscode", "NAME=gateway"]
                , assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["charts", "status", "vscode"]
                    ["CHART_STATUS", "NAME=vscode"]
                ]
        ValidationChartsStorage ->
            runSequentially
                [ assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["charts", "status", "vscode"]
                    ["CHART_STATUS", "STORAGE_BINDING"]
                , assertNativeCommandOutputContainsAll
                    repoRoot
                    environment
                    ["charts", "delete", "vscode", "--yes"]
                    ["CHART_DELETION", "HOST_STORAGE_PRESERVED=true"]
                ]
        ValidationLifecycle ->
            runSequentially
                [ runNativeCliCommandForExitCode repoRoot environment ["rke2", "delete", "--yes"]
                , runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"]
                , runNativeCliCommandForExitCode repoRoot environment ["k8s", "health"]
                ]

runChartsVscodeValidation :: FilePath -> IO ExitCode
runChartsVscodeValidation repoRoot = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings -> do
            readyExit <- waitForPublicEdgeReady repoRoot
            case readyExit of
                ExitFailure _ -> pure readyExit
                ExitSuccess -> do
                    let fqdn = preferredPublicHostFqdn settings
                    assertCommandOutputContainsAll
                        CommandSpec
                            { commandPath = "curl"
                            , commandArguments = ["-sSIL", "--max-time", "20", "https://" ++ fqdn]
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                        ["HTTP/"]

waitForPublicEdgeReady :: FilePath -> IO ExitCode
waitForPublicEdgeReady repoRoot = do
    let spec =
            CommandSpec
                { commandPath = canonicalOperatorBinaryPath repoRoot
                , commandArguments = ["host", "public-edge"]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }
    waitForClassification spec publicEdgeReadyAttempts
  where
    waitForClassification :: CommandSpec -> Int -> IO ExitCode
    waitForClassification spec attemptsLeft = do
        outputResult <- captureCommand spec
        case outputResult of
            Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
            Success output -> do
                let combinedOutput = processStdout output ++ processStderr output
                putStr (processStdout output)
                hPutStr stderr (processStderr output)
                case processExitCode output of
                    ExitFailure code ->
                        failWith
                            ( "`"
                                ++ commandDisplay spec
                                ++ "` exited with code "
                                ++ show code
                            )
                    ExitSuccess
                        | publicEdgeReadyClassification `isInfixOf` combinedOutput -> pure ExitSuccess
                        | attemptsLeft <= 1 ->
                            failWith
                                ( "`"
                                    ++ commandDisplay spec
                                    ++ "` did not report required output `"
                                    ++ publicEdgeReadyClassification
                                    ++ "` before timeout."
                                )
                        | otherwise -> do
                            hPutStrLn stderr "Waiting for public edge readiness before external curl validation."
                            threadDelay publicEdgeReadyDelayMicroseconds
                            waitForClassification spec (attemptsLeft - 1)

runPublicDnsValidation :: FilePath -> IO ExitCode
runPublicDnsValidation repoRoot = do
    settingsEnvResult <- settingsAwsEnvironment repoRoot
    case settingsEnvResult of
        Left err -> failWith err
        Right (settings, awsEnvironment) -> do
            zonePayloadResult <-
                runJsonCommand
                    CommandSpec
                        { commandPath = "aws"
                        , commandArguments =
                            [ "route53"
                            , "get-hosted-zone"
                            , "--id"
                            , textValue (zone_id (route53 (validatedConfig settings)))
                            , "--output"
                            , "json"
                            ]
                        , commandEnvironment = Just awsEnvironment
                        , commandWorkingDirectory = Just repoRoot
                        }
            case zonePayloadResult of
                Left err -> failWith err
                Right payload ->
                    case hostedZoneDelegation payload of
                        Left err -> failWith err
                        Right (zoneName, expectedNameservers) -> do
                            digResult <-
                                runTextCommand
                                    CommandSpec
                                        { commandPath = "dig"
                                        , commandArguments = ["+short", "NS", zoneName]
                                        , commandEnvironment = Nothing
                                        , commandWorkingDirectory = Just repoRoot
                                        }
                            case digResult of
                                Left err -> failWith err
                                Right stdoutText -> do
                                    let actualNameservers = sort (map normalizeDnsValue (filter (/= "") (lines stdoutText)))
                                        expectedNormalized = sort (map normalizeDnsValue expectedNameservers)
                                    if actualNameservers == expectedNormalized
                                        then pure ExitSuccess
                                        else
                                            failWith
                                                ( "Public NS delegation mismatch for "
                                                    ++ zoneName
                                                    ++ ": expected "
                                                    ++ show expectedNormalized
                                                    ++ " but found "
                                                    ++ show actualNameservers
                                                )

runDnsAwsValidation :: FilePath -> IO ExitCode
runDnsAwsValidation repoRoot = do
    settingsEnvResult <- settingsAwsEnvironment repoRoot
    case settingsEnvResult of
        Left err -> failWith err
        Right (settings, awsEnvironment) -> do
            baseZoneNameResult <- configuredHostedZoneName repoRoot awsEnvironment settings
            case baseZoneNameResult of
                Left err -> failWith err
                Right baseZoneName -> do
                    nonce <- validationNonce
                    let zoneName = "prodbox-dns-aws-" ++ nonce ++ "." ++ baseZoneName
                        recordName = "gateway." ++ zoneName
                        recordIp = "203.0.113.10"
                        callerReference = "prodbox-dns-aws-" ++ nonce
                    createZoneResult <-
                        runTextCommand
                            CommandSpec
                                { commandPath = "aws"
                                , commandArguments =
                                    [ "route53"
                                    , "create-hosted-zone"
                                    , "--name"
                                    , zoneName
                                    , "--caller-reference"
                                    , callerReference
                                    , "--query"
                                    , "HostedZone.Id"
                                    , "--output"
                                    , "text"
                                    ]
                                , commandEnvironment = Just awsEnvironment
                                , commandWorkingDirectory = Just repoRoot
                                }
                    case createZoneResult of
                        Left err -> failWith err
                        Right zoneId -> do
                            let hostedZoneId = trim zoneId
                            validationExit <- do
                                upsertExit <- changeRoute53Record repoRoot awsEnvironment hostedZoneId "UPSERT" recordName recordIp
                                case upsertExit of
                                    ExitFailure _ -> pure upsertExit
                                    ExitSuccess -> do
                                        verifyResult <-
                                            runTextCommand
                                                CommandSpec
                                                    { commandPath = "aws"
                                                    , commandArguments =
                                                        [ "route53"
                                                        , "list-resource-record-sets"
                                                        , "--hosted-zone-id"
                                                        , hostedZoneId
                                                        , "--query"
                                                        , "ResourceRecordSets[?Name == '"
                                                            ++ ensureTrailingDot recordName
                                                            ++ "'].ResourceRecords[0].Value | [0]"
                                                        , "--output"
                                                        , "text"
                                                        ]
                                                    , commandEnvironment = Just awsEnvironment
                                                    , commandWorkingDirectory = Just repoRoot
                                                    }
                                        case verifyResult of
                                            Left err -> failWith err
                                            Right value ->
                                                if trim value == recordIp
                                                    then pure ExitSuccess
                                                    else
                                                        failWith
                                                            ( "Route 53 record lifecycle validation failed: expected "
                                                                ++ recordIp
                                                                ++ " but found "
                                                                ++ trim value
                                                            )
                            cleanupExit <- cleanupDnsAwsValidation repoRoot awsEnvironment hostedZoneId recordName recordIp
                            case (validationExit, cleanupExit) of
                                (ExitSuccess, ExitSuccess) -> pure ExitSuccess
                                (ExitFailure _, _) -> pure validationExit
                                (_, ExitFailure _) -> pure cleanupExit

configuredHostedZoneName :: FilePath -> [(String, String)] -> ValidatedSettings -> IO (Either String String)
configuredHostedZoneName repoRoot awsEnvironment settings = do
    zonePayloadResult <-
        runJsonCommand
            CommandSpec
                { commandPath = "aws"
                , commandArguments =
                    [ "route53"
                    , "get-hosted-zone"
                    , "--id"
                    , textValue (zone_id (route53 (validatedConfig settings)))
                    , "--output"
                    , "json"
                    ]
                , commandEnvironment = Just awsEnvironment
                , commandWorkingDirectory = Just repoRoot
                }
    case zonePayloadResult of
        Left err -> pure (Left err)
        Right payload ->
            case hostedZoneDelegation payload of
                Left err -> pure (Left err)
                Right (zoneName, _) -> pure (Right (trimTrailingDot zoneName))

cleanupDnsAwsValidation ::
    FilePath ->
    [(String, String)] ->
    String ->
    String ->
    String ->
    IO ExitCode
cleanupDnsAwsValidation repoRoot awsEnvironment hostedZoneId recordName recordIp = do
    deleteRecordExit <- changeRoute53Record repoRoot awsEnvironment hostedZoneId "DELETE" recordName recordIp
    case deleteRecordExit of
        ExitFailure _ -> pure deleteRecordExit
        ExitSuccess ->
            runCommandForExitCode
                CommandSpec
                    { commandPath = "aws"
                    , commandArguments =
                        [ "route53"
                        , "delete-hosted-zone"
                        , "--id"
                        , hostedZoneId
                        ]
                    , commandEnvironment = Just awsEnvironment
                    , commandWorkingDirectory = Just repoRoot
                    }

changeRoute53Record ::
    FilePath ->
    [(String, String)] ->
    String ->
    String ->
    String ->
    String ->
    IO ExitCode
changeRoute53Record repoRoot awsEnvironment hostedZoneId action recordName recordIp = do
    (batchPath, handle) <- openTempFile repoRoot "route53-change-batch.json"
    hClose handle
    writeResult <-
        try
            ( writeFile
                batchPath
                ( route53ChangeBatch action recordName recordIp
                )
            ) ::
            IO (Either IOException ())
    case writeResult of
        Left err -> failWith ("failed to write Route 53 change batch: " ++ show err)
        Right () -> do
            changeResult <-
                runTextCommand
                    CommandSpec
                        { commandPath = "aws"
                        , commandArguments =
                            [ "route53"
                            , "change-resource-record-sets"
                            , "--hosted-zone-id"
                            , hostedZoneId
                            , "--change-batch"
                            , "file://" ++ batchPath
                            , "--query"
                            , "ChangeInfo.Id"
                            , "--output"
                            , "text"
                            ]
                        , commandEnvironment = Just awsEnvironment
                        , commandWorkingDirectory = Just repoRoot
                        }
            _ <- try (removeFile batchPath) :: IO (Either IOException ())
            case changeResult of
                Left err -> failWith err
                Right changeId ->
                    runCommandForExitCode
                        CommandSpec
                            { commandPath = "aws"
                            , commandArguments =
                                [ "route53"
                                , "wait"
                                , "resource-record-sets-changed"
                                , "--id"
                                , trim changeId
                                ]
                            , commandEnvironment = Just awsEnvironment
                            , commandWorkingDirectory = Just repoRoot
                            }

route53ChangeBatch :: String -> String -> String -> String
route53ChangeBatch action recordName recordIp =
    unlines
        [ "{"
        , "  \"Changes\": ["
        , "    {"
        , "      \"Action\": \"" ++ action ++ "\","
        , "      \"ResourceRecordSet\": {"
        , "        \"Name\": \"" ++ ensureTrailingDot recordName ++ "\","
        , "        \"Type\": \"A\","
        , "        \"TTL\": 60,"
        , "        \"ResourceRecords\": [{\"Value\": \"" ++ recordIp ++ "\"}]"
        , "      }"
        , "    }"
        , "  ]"
        , "}"
        ]

runGatewayDaemonValidation :: FilePath -> [(String, String)] -> IO ExitCode
runGatewayDaemonValidation repoRoot environment = do
    (configPath, handle) <- openTempFile repoRoot "gateway-validation.json"
    hClose handle
    configExit <-
        runNativeCliCommandForExitCode
            repoRoot
            environment
            ["gateway", "config-gen", configPath, "--node-id", "validation-node"]
    case configExit of
        ExitFailure _ -> pure configExit
        ExitSuccess -> do
            configReadResult <- try (readFile configPath) :: IO (Either IOException String)
            _ <- try (removeFile configPath) :: IO (Either IOException ())
            case configReadResult of
                Left err -> failWith ("failed to read generated gateway config: " ++ show err)
                Right configText ->
                    if "\"dns_write_gate\"" `isInfixOf` configText && "\"node_id\": \"validation-node\"" `isInfixOf` configText
                        then runNativeCliCommandForExitCode repoRoot environment ["k8s", "logs", "--namespace", "prodbox", "--tail", "20"]
                        else failWith "generated gateway config did not include the expected node_id and dns_write_gate fields"

verifyAwsEksSnapshot :: FilePath -> IO ExitCode
verifyAwsEksSnapshot repoRoot = do
    snapshot <- AwsEks.loadAwsEksTestStackSnapshot repoRoot
    case snapshot of
        Nothing -> failWith "AWS EKS validation did not produce a saved stack snapshot"
        Just current ->
            if null (AwsEks.eksSnapshotClusterName current) || null (AwsEks.eksSnapshotSubnetIds current)
                then failWith "AWS EKS snapshot was incomplete"
                else pure ExitSuccess

verifyAwsTestSnapshot :: FilePath -> IO ExitCode
verifyAwsTestSnapshot repoRoot = do
    snapshot <- AwsTest.loadAwsTestStackSnapshot repoRoot
    case snapshot of
        Nothing -> failWith "AWS test-stack validation did not produce a saved stack snapshot"
        Just current ->
            if length (AwsTest.testSnapshotNodes current) /= 3
                then failWith "AWS test-stack snapshot did not contain the expected three-node topology"
                else pure ExitSuccess

verifyAwsTestSshReachability :: FilePath -> IO ExitCode
verifyAwsTestSshReachability repoRoot = do
    keyResult <- AwsTest.ensureAwsTestSshKey repoRoot
    snapshot <- AwsTest.loadAwsTestStackSnapshot repoRoot
    case (keyResult, snapshot) of
        (Left err, _) -> failWith err
        (_, Nothing) -> failWith "AWS test-stack SSH validation requires an existing saved stack snapshot"
        (Right privateKeyPath, Just current) ->
            foldM
                ( \exitCode node ->
                    case exitCode of
                        ExitFailure _ -> pure exitCode
                        ExitSuccess -> waitForAwsTestNodeSsh repoRoot privateKeyPath node awsTestSshReadyAttempts
                )
                ExitSuccess
                (AwsTest.testSnapshotNodes current)

waitForAwsTestNodeSsh :: FilePath -> FilePath -> AwsTest.AwsTestNode -> Int -> IO ExitCode
waitForAwsTestNodeSsh repoRoot privateKeyPath node attemptsLeft = do
    let spec =
            CommandSpec
                { commandPath = "ssh"
                , commandArguments =
                    [ "-i"
                    , privateKeyPath
                    , "-o"
                    , "BatchMode=yes"
                    , "-o"
                    , "StrictHostKeyChecking=no"
                    , "-o"
                    , "UserKnownHostsFile=/dev/null"
                    , "-o"
                    , "ConnectTimeout=20"
                    , "ubuntu@" ++ AwsTest.testNodePublicIp node
                    , "hostname"
                    ]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
                }
        nodeLabel = AwsTest.testNodeName node ++ " (" ++ AwsTest.testNodePublicIp node ++ ")"
    outputResult <- captureCommand spec
    case outputResult of
        Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
        Success output ->
            case processExitCode output of
                ExitSuccess -> do
                    putStr (processStdout output)
                    hPutStr stderr (processStderr output)
                    pure ExitSuccess
                ExitFailure _
                    | attemptsLeft > 1 && shouldRetryAwsTestSsh (outputDetail output) -> do
                        hPutStrLn stderr ("Waiting for AWS test-stack SSH readiness on " ++ nodeLabel ++ " before retry: " ++ outputDetail output)
                        threadDelay awsTestSshReadyDelayMicroseconds
                        waitForAwsTestNodeSsh repoRoot privateKeyPath node (attemptsLeft - 1)
                    | otherwise ->
                        failWith
                            ( "AWS test-stack SSH validation failed for "
                                ++ nodeLabel
                                ++ ": "
                                ++ outputDetail output
                            )

shouldRetryAwsTestSsh :: String -> Bool
shouldRetryAwsTestSsh detail =
    let lowered = map toLowerAscii detail
     in any
            (`isInfixOf` lowered)
            [ "connection refused"
            , "connection timed out"
            , "operation timed out"
            , "connection reset by peer"
            , "connection closed by remote host"
            , "no route to host"
            , "host is down"
            , "network is unreachable"
            ]

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially = foldM step ExitSuccess
  where
    step failure@(ExitFailure _) _ = pure failure
    step ExitSuccess action = action

runNativeCliCommandForExitCode :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runNativeCliCommandForExitCode repoRoot environment cliArgs = do
    runCommandForExitCode (nativeCliCommandSpec repoRoot environment cliArgs)

assertNativeCommandOutputContainsAll :: FilePath -> [(String, String)] -> [String] -> [String] -> IO ExitCode
assertNativeCommandOutputContainsAll repoRoot environment cliArgs expectedTexts = do
    assertCommandOutputContainsAll (nativeCliCommandSpec repoRoot environment cliArgs) expectedTexts

assertProducedOutputContainsAll :: String -> IO String -> [String] -> IO ExitCode
assertProducedOutputContainsAll label outputAction expectedTexts = do
    outputResult <- try outputAction :: IO (Either SomeException String)
    case outputResult of
        Left err -> failWith ("`" ++ label ++ "` failed: " ++ displayException err)
        Right output -> do
            putStr output
            if all (`isInfixOf` output) expectedTexts
                then pure ExitSuccess
                else
                    failWith
                        ( "`"
                            ++ label
                            ++ "` did not report all required output fragments: "
                            ++ show expectedTexts
                        )

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> CommandSpec
nativeCliCommandSpec repoRoot environment cliArgs =
    CommandSpec
        { commandPath = canonicalOperatorBinaryPath repoRoot
        , commandArguments = cliArgs
        , commandEnvironment = Just environment
        , commandWorkingDirectory = Just repoRoot
        }

runCommandForExitCode :: CommandSpec -> IO ExitCode
runCommandForExitCode spec = do
    commandResult <- runStreamingCommand spec
    case commandResult of
        Failure err -> failWith err
        Success exitCode -> pure exitCode

assertCommandOutputContainsAll :: CommandSpec -> [String] -> IO ExitCode
assertCommandOutputContainsAll spec expectedTexts = do
    outputResult <- captureCommand spec
    case outputResult of
        Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
        Success output -> do
            putStr (processStdout output)
            hPutStr stderr (processStderr output)
            case processExitCode output of
                ExitFailure code ->
                    failWith
                        ( "`"
                            ++ commandDisplay spec
                            ++ "` exited with code "
                            ++ show code
                        )
                ExitSuccess ->
                    let combinedOutput = processStdout output ++ processStderr output
                     in if all (`isInfixOf` combinedOutput) expectedTexts
                            then pure ExitSuccess
                            else
                                failWith
                                    ( "`"
                                        ++ commandDisplay spec
                                        ++ "` did not report all required output fragments: "
                                        ++ show expectedTexts
                                    )

runTextCommand :: CommandSpec -> IO (Either String String)
runTextCommand spec = do
    outputResult <- captureCommand spec
    pure $
        case outputResult of
            Failure err -> Left ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
            Success output ->
                case processExitCode output of
                    ExitSuccess -> Right (processStdout output)
                    ExitFailure _ ->
                        Left
                            ( "`"
                                ++ commandDisplay spec
                                ++ "` failed: "
                                ++ outputDetail output
                            )

runJsonCommand :: CommandSpec -> IO (Either String Value)
runJsonCommand spec = do
    textResult <- runTextCommand spec
    pure $ do
        stdoutText <- textResult
        eitherDecode (BL8.pack stdoutText)

settingsAwsEnvironment :: FilePath -> IO (Either String (ValidatedSettings, [(String, String)]))
settingsAwsEnvironment repoRoot = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> pure (Left err)
        Right settings -> do
            currentEnvironment <- getEnvironment
            pure
                ( Right
                    ( settings
                    , overlayAwsCredentials currentEnvironment (aws (validatedConfig settings))
                    )
                )

hostedZoneDelegation :: Value -> Either String (String, [String])
hostedZoneDelegation payload =
    case payload of
        Object rootObject -> do
            hostedZoneValue <- requireObjectField rootObject "HostedZone"
            zoneName <- requireStringField hostedZoneValue "Name"
            delegationValue <- requireObjectField rootObject "DelegationSet"
            nameservers <- requireStringArrayField delegationValue "NameServers"
            Right (zoneName, nameservers)
        _ -> Left "aws route53 get-hosted-zone did not return a JSON object"

requireObjectField :: KeyMap.KeyMap Value -> String -> Either String (KeyMap.KeyMap Value)
requireObjectField object key =
    case KeyMap.lookup (Key.fromString key) object of
        Just (Object nested) -> Right nested
        _ -> Left ("missing object field " ++ key)

requireStringField :: KeyMap.KeyMap Value -> String -> Either String String
requireStringField object key =
    case KeyMap.lookup (Key.fromString key) object of
        Just (String value) -> Right (textValue value)
        _ -> Left ("missing string field " ++ key)

requireStringArrayField :: KeyMap.KeyMap Value -> String -> Either String [String]
requireStringArrayField object key =
    case KeyMap.lookup (Key.fromString key) object of
        Just (Array values) ->
            mapM
                ( \value ->
                    case value of
                        String textVal -> Right (textValue textVal)
                        _ -> Left ("field " ++ key ++ " must contain strings only")
                )
                (Vector.toList values)
        _ -> Left ("missing array field " ++ key)

validationNonce :: IO String
validationNonce = show . (round :: Rational -> Integer) . toRational <$> getPOSIXTime

normalizeDnsValue :: String -> String
normalizeDnsValue = trimTrailingDot . map toLowerAscii . trim

ensureTrailingDot :: String -> String
ensureTrailingDot value =
    if null value || last value == '.'
        then value
        else value ++ "."

trimTrailingDot :: String -> String
trimTrailingDot value =
    if not (null value) && last value == '.'
        then init value
        else value

trim :: String -> String
trim = reverse . dropWhile (`elem` [' ', '\n', '\r', '\t']) . reverse . dropWhile (`elem` [' ', '\n', '\r', '\t'])

toLowerAscii :: Char -> Char
toLowerAscii char
    | isAsciiUpper char = toEnum (fromEnum char + 32)
    | otherwise = char

textValue :: Text.Text -> String
textValue = Text.unpack

outputDetail :: ProcessOutput -> String
outputDetail output =
    case (trim (processStderr output), trim (processStdout output)) of
        (stderrText, _) | stderrText /= "" -> stderrText
        ("", stdoutText) | stdoutText /= "" -> stdoutText
        _ -> "subprocess exited without output"

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
