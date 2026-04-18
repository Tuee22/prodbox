{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Pulumi
    ( runPulumiCommand,
    )
where

import Control.Exception
    ( IOException,
      bracket,
      displayException,
      try,
    )
import Control.Monad (foldM)
import Data.Aeson
    ( encode,
      object,
      (.=),
    )
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Lazy as BL
import Data.Char (toLower)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import Prodbox.CLI.Command (PulumiCommand (..))
import qualified Prodbox.Infra.AwsEksTestStack as EksStack
import qualified Prodbox.Infra.AwsTestStack as TestStack
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
      getTemporaryDirectory,
      removeFile,
    )
import System.Environment (getEnvironment)
import System.Exit
    ( ExitCode (ExitFailure, ExitSuccess),
    )
import System.FilePath ((</>))
import System.IO
    ( hClose,
      hPutStrLn,
      openTempFile,
      stderr,
    )

prodboxNamespace :: String
prodboxNamespace = "prodbox"

prodboxIdentityConfigMap :: String
prodboxIdentityConfigMap = "prodbox-identity"

prodboxAnnotationKey :: String
prodboxAnnotationKey = "prodbox.io/id"

prodboxLabelKey :: String
prodboxLabelKey = "prodbox.io/id"

prodboxManagedNamespaces :: [String]
prodboxManagedNamespaces =
    [ prodboxNamespace,
      "harbor",
      "metallb-system",
      "traefik-system",
      "cert-manager",
      "gateway",
      "vscode"
    ]

prodboxHelmInstances :: [String]
prodboxHelmInstances =
    [ "harbor",
      "minio",
      "metallb",
      "traefik",
      "cert-manager"
    ]

prodboxEphemeralResourceKinds :: [String]
prodboxEphemeralResourceKinds =
    [ "events",
      "events.events.k8s.io"
    ]

prodboxDoctrineCrdSuffixes :: [String]
prodboxDoctrineCrdSuffixes =
    [ ".metallb.io",
      ".cert-manager.io",
      ".acme.cert-manager.io",
      ".traefik.io",
      ".containo.us"
    ]

runPulumiCommand :: FilePath -> PulumiCommand -> IO ExitCode
runPulumiCommand repoRoot command =
    case command of
        PulumiUp confirmed -> runHomeStackApply repoRoot confirmed
        PulumiDestroy confirmed -> runHomeStackCommand repoRoot False (pulumiDestroyArgs confirmed)
        PulumiPreview -> runHomeStackCommand repoRoot False pulumiPreviewArgs
        PulumiRefresh -> runHomeStackCommand repoRoot True pulumiRefreshArgs
        PulumiStackInit stackName -> runStackInitCommand repoRoot stackName
        PulumiEksResources -> EksStack.ensureAwsEksTestStackResources repoRoot
        PulumiEksDestroy _ -> EksStack.destroyAwsEksTestStack repoRoot
        PulumiTestResources -> TestStack.ensureAwsTestStackResources repoRoot
        PulumiTestDestroy _ -> TestStack.destroyAwsTestStack repoRoot

yesArgs :: Bool -> [String]
yesArgs confirmed = ["--yes" | confirmed]

homeStackName :: String
homeStackName = "home"

runHomeStackApply :: FilePath -> Bool -> IO ExitCode
runHomeStackApply repoRoot confirmed =
    withHomeStackEnvironment repoRoot True $ \environment -> do
        applyExit <-
            runCommand
                CommandSpec
                    { commandPath = "pulumi",
                      commandArguments = pulumiUpArgs confirmed,
                      commandEnvironment = Just environment,
                      commandWorkingDirectory = Just repoRoot
                    }
        case applyExit of
            ExitFailure _ -> pure applyExit
            ExitSuccess -> reconcilePulumiApplyMetadata repoRoot

runHomeStackCommand :: FilePath -> Bool -> [String] -> IO ExitCode
runHomeStackCommand repoRoot createIfMissing commandArguments =
    withHomeStackEnvironment repoRoot createIfMissing $ \environment ->
        runCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = commandArguments,
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just repoRoot
                }

withHomeStackEnvironment :: FilePath -> Bool -> ([(String, String)] -> IO ExitCode) -> IO ExitCode
withHomeStackEnvironment repoRoot createIfMissing action = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings -> do
            environmentResult <- pulumiEnvironment repoRoot settings
            case environmentResult of
                Left err -> failWith err
                Right environment -> do
                    loginExit <- ensurePulumiLogin repoRoot environment
                    case loginExit of
                        ExitFailure _ -> pure loginExit
                        _ -> do
                            stackExit <- selectPulumiStack repoRoot environment createIfMissing homeStackName
                            case stackExit of
                                ExitFailure _ -> pure stackExit
                                _ -> action environment

runStackInitCommand :: FilePath -> String -> IO ExitCode
runStackInitCommand repoRoot stackName = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
        Left err -> failWith err
        Right settings -> do
            environmentResult <- pulumiEnvironment repoRoot settings
            case environmentResult of
                Left err -> failWith err
                Right environment -> do
                    loginExit <- ensurePulumiLogin repoRoot environment
                    case loginExit of
                        ExitFailure _ -> pure loginExit
                        _ ->
                            runCommand
                                CommandSpec
                                    { commandPath = "pulumi",
                                      commandArguments = ["stack", "init", stackName],
                                      commandEnvironment = Just environment,
                                      commandWorkingDirectory = Just repoRoot
                                    }

pulumiPreviewArgs :: [String]
pulumiPreviewArgs = ["preview", "--stack", homeStackName]

pulumiUpArgs :: Bool -> [String]
pulumiUpArgs confirmed =
    ["up"] ++ yesArgs confirmed ++ ["--stack", homeStackName]

pulumiDestroyArgs :: Bool -> [String]
pulumiDestroyArgs confirmed =
    ["destroy"] ++ yesArgs confirmed ++ ["--stack", homeStackName]

pulumiRefreshArgs :: [String]
pulumiRefreshArgs = ["refresh", "--stack", homeStackName]

ensurePulumiLogin :: FilePath -> [(String, String)] -> IO ExitCode
ensurePulumiLogin repoRoot environment = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments = ["whoami"],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just repoRoot
                }
    case result of
        Failure err -> failWith err
        Success output ->
            case processExitCode output of
                ExitFailure _ -> failWith ("pulumi whoami failed: " ++ outputDetail output)
                _ -> pure (processExitCode output)

selectPulumiStack :: FilePath -> [(String, String)] -> Bool -> String -> IO ExitCode
selectPulumiStack repoRoot environment createIfMissing stackName = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "pulumi",
                  commandArguments =
                    [ "stack",
                      "select",
                      stackName
                    ]
                        ++ ["--create" | createIfMissing],
                  commandEnvironment = Just environment,
                  commandWorkingDirectory = Just repoRoot
                }
    case result of
        Failure err -> failWith err
        Success output ->
            case processExitCode output of
                ExitFailure _ ->
                    failWith
                        ( "pulumi stack select failed for "
                            ++ stackName
                            ++ ": "
                            ++ outputDetail output
                        )
                _ -> pure (processExitCode output)

reconcilePulumiApplyMetadata :: FilePath -> IO ExitCode
reconcilePulumiApplyMetadata repoRoot = do
    machineIdentityResult <- resolveMachineIdentity
    case machineIdentityResult of
        Left err -> failWith err
        Right (machineId, prodboxId) -> do
            let labelValue = prodboxIdToLabelValue prodboxId
            configMapExit <- ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue
            case configMapExit of
                ExitFailure _ -> pure configMapExit
                ExitSuccess -> reconcileManagedAnnotations repoRoot prodboxId labelValue

ensureProdboxIdentityConfigMap :: FilePath -> String -> String -> String -> IO ExitCode
ensureProdboxIdentityConfigMap repoRoot machineId prodboxId labelValue =
    withTemporaryJsonFile "prodbox-identity" manifest $ \manifestPath -> do
        outputResult <- captureKubectl repoRoot ["apply", "-f", manifestPath]
        case outputResult of
            Left err -> failWith err
            Right output ->
                case processExitCode output of
                    ExitSuccess -> pure ExitSuccess
                    ExitFailure _ -> failWith ("kubectl apply failed: " ++ outputDetail output)
  where
    manifest =
        encode $
            object
                [ "apiVersion" .= ("v1" :: String),
                  "kind" .= ("List" :: String),
                  "items"
                    .= [ object
                            [ "apiVersion" .= ("v1" :: String),
                              "kind" .= ("Namespace" :: String),
                              "metadata"
                                .= object
                                    [ "name" .= prodboxNamespace,
                                      "annotations"
                                        .= object
                                            [ Key.fromString prodboxAnnotationKey .= prodboxId
                                            ],
                                      "labels"
                                        .= object
                                            [ Key.fromString prodboxLabelKey .= labelValue
                                            ]
                                    ]
                            ],
                         object
                            [ "apiVersion" .= ("v1" :: String),
                              "kind" .= ("ConfigMap" :: String),
                              "metadata"
                                .= object
                                    [ "name" .= prodboxIdentityConfigMap,
                                      "namespace" .= prodboxNamespace,
                                      "annotations"
                                        .= object
                                            [ Key.fromString prodboxAnnotationKey .= prodboxId
                                            ],
                                      "labels"
                                        .= object
                                            [ Key.fromString prodboxLabelKey .= labelValue
                                            ]
                                    ],
                              "data"
                                .= object
                                    [ "machine_id" .= machineId,
                                      "prodbox_id" .= prodboxId
                                    ]
                            ]
                       ]
                ]

reconcileManagedAnnotations :: FilePath -> String -> String -> IO ExitCode
reconcileManagedAnnotations repoRoot prodboxId labelValue = do
    namespacedResourcesResult <- listApiResources repoRoot True
    clusterResourcesResult <- listApiResources repoRoot False
    case (namespacedResourcesResult, clusterResourcesResult) of
        (Left err, _) -> failWith err
        (_, Left err) -> failWith err
        (Right namespacedResources, Right clusterResources) -> do
            let namespaceActions =
                    concat
                        [ [ annotateObject repoRoot Nothing ("namespace/" ++ namespace) prodboxId labelValue,
                            annotateNamespacedResources repoRoot namespace namespacedResources prodboxId labelValue
                          ]
                        | namespace <- prodboxManagedNamespaces
                        ]
                instanceActions =
                    [ annotateClusterResources repoRoot instanceName clusterResources prodboxId labelValue
                    | instanceName <- prodboxHelmInstances
                    ]
            result <-
                runEitherActions
                    ( namespaceActions
                        ++ instanceActions
                        ++ [annotateDoctrineCrds repoRoot prodboxId labelValue]
                    )
            either failWith (const (pure ExitSuccess)) result

listApiResources :: FilePath -> Bool -> IO (Either String [String])
listApiResources repoRoot namespaced = do
    outputResult <-
        captureKubectl
            repoRoot
            [ "api-resources",
              "--verbs=list",
              "--namespaced=" ++ map toLower (show namespaced),
              "-o",
              "name"
            ]
    pure $ do
        output <- outputResult
        case processExitCode output of
            ExitFailure _ ->
                Left ("Failed to list Kubernetes API resources: " ++ outputDetail output)
            ExitSuccess ->
                Right
                    ( filter (`notElem` prodboxEphemeralResourceKinds)
                        (nonEmptyLines (processStdout output))
                    )

annotateNamespacedResources :: FilePath -> String -> [String] -> String -> String -> IO (Either String ())
annotateNamespacedResources repoRoot namespace resources prodboxId labelValue =
    runEitherActions
        [ annotateNamespacedResource repoRoot namespace resource prodboxId labelValue
        | resource <- resources
        ]

annotateNamespacedResource :: FilePath -> String -> String -> String -> String -> IO (Either String ())
annotateNamespacedResource repoRoot namespace resource prodboxId labelValue = do
    outputResult <-
        captureKubectl
            repoRoot
            [ "get",
              resource,
              "-n",
              namespace,
              "-o",
              "name",
              "--ignore-not-found=true"
            ]
    case outputResult of
        Left err -> pure (Left err)
        Right output ->
            case processExitCode output of
                ExitFailure _ ->
                    if isIgnorableListingError (outputDetail output)
                        then pure (Right ())
                        else pure (Left ("list " ++ resource ++ " in " ++ namespace ++ " failed: " ++ outputDetail output))
                ExitSuccess ->
                    if null (parseObjectNames (processStdout output))
                        then pure (Right ())
                        else annotateResourceSet repoRoot (Just namespace) resource Nothing prodboxId labelValue

annotateClusterResources :: FilePath -> String -> [String] -> String -> String -> IO (Either String ())
annotateClusterResources repoRoot instanceName resources prodboxId labelValue =
    runEitherActions
        [ annotateClusterResource repoRoot instanceName resource prodboxId labelValue
        | resource <- resources
        ]

annotateClusterResource :: FilePath -> String -> String -> String -> String -> IO (Either String ())
annotateClusterResource repoRoot instanceName resource prodboxId labelValue = do
    let selector = "app.kubernetes.io/instance=" ++ instanceName
    outputResult <-
        captureKubectl
            repoRoot
            [ "get",
              resource,
              "-l",
              selector,
              "-o",
              "name",
              "--ignore-not-found=true"
            ]
    case outputResult of
        Left err -> pure (Left err)
        Right output ->
            case processExitCode output of
                ExitFailure _ ->
                    if isIgnorableListingError (outputDetail output)
                        then pure (Right ())
                        else pure (Left ("list cluster " ++ resource ++ " for " ++ instanceName ++ " failed: " ++ outputDetail output))
                ExitSuccess ->
                    if null (parseObjectNames (processStdout output))
                        then pure (Right ())
                        else annotateResourceSet repoRoot Nothing resource (Just selector) prodboxId labelValue

annotateDoctrineCrds :: FilePath -> String -> String -> IO (Either String ())
annotateDoctrineCrds repoRoot prodboxId labelValue = do
    outputResult <- captureKubectl repoRoot ["get", "crd", "-o", "name"]
    case outputResult of
        Left err -> pure (Left err)
        Right output ->
            case processExitCode output of
                ExitFailure _ ->
                    if isIgnorableListingError (outputDetail output)
                        then pure (Right ())
                        else pure (Left ("list CRDs failed: " ++ outputDetail output))
                ExitSuccess ->
                    runEitherActions
                        [ annotateObject repoRoot Nothing ref prodboxId labelValue
                        | ref <- parseObjectNames (processStdout output),
                          any (`isInfixOf` dropResourcePrefix ref) prodboxDoctrineCrdSuffixes
                        ]

annotateObject :: FilePath -> Maybe String -> String -> String -> String -> IO (Either String ())
annotateObject repoRoot maybeNamespace objectRef prodboxId labelValue = do
    annotateResult <-
        captureKubectl
            repoRoot
            ( appendNamespaceArgs
                maybeNamespace
                ["annotate", objectRef, prodboxAnnotationKey ++ "=" ++ prodboxId, "--overwrite"]
            )
    case annotateResult of
        Left err -> pure (Left err)
        Right annotateOutput ->
            if shouldIgnoreAnnotationFailure annotateOutput
                then pure (Right ())
                else
                    case processExitCode annotateOutput of
                        ExitFailure _ -> pure (Left ("annotate " ++ objectRef ++ " failed: " ++ outputDetail annotateOutput))
                        ExitSuccess -> do
                            labelResult <-
                                captureKubectl
                                    repoRoot
                                    ( appendNamespaceArgs
                                        maybeNamespace
                                        ["label", objectRef, prodboxLabelKey ++ "=" ++ labelValue, "--overwrite"]
                                    )
                            case labelResult of
                                Left err -> pure (Left err)
                                Right labelOutput ->
                                    if shouldIgnoreAnnotationFailure labelOutput
                                        then pure (Right ())
                                        else
                                            case processExitCode labelOutput of
                                                ExitFailure _ -> pure (Left ("label " ++ objectRef ++ " failed: " ++ outputDetail labelOutput))
                                                ExitSuccess -> pure (Right ())

annotateResourceSet ::
    FilePath ->
    Maybe String ->
    String ->
    Maybe String ->
    String ->
    String ->
    IO (Either String ())
annotateResourceSet repoRoot maybeNamespace resource maybeSelector prodboxId labelValue = do
    annotateResult <-
        captureKubectl
            repoRoot
            ( appendNamespaceArgs maybeNamespace
                ( ["annotate", resource]
                    ++ selectorArgs maybeSelector
                    ++ ["--all", prodboxAnnotationKey ++ "=" ++ prodboxId, "--overwrite"]
                )
            )
    case annotateResult of
        Left err -> pure (Left err)
        Right annotateOutput ->
            if shouldIgnoreAnnotationFailure annotateOutput
                then pure (Right ())
                else
                    case processExitCode annotateOutput of
                        ExitFailure _ -> pure (Left ("annotate " ++ resource ++ " failed: " ++ outputDetail annotateOutput))
                        ExitSuccess -> do
                            labelResult <-
                                captureKubectl
                                    repoRoot
                                    ( appendNamespaceArgs maybeNamespace
                                        ( ["label", resource]
                                            ++ selectorArgs maybeSelector
                                            ++ ["--all", prodboxLabelKey ++ "=" ++ labelValue, "--overwrite"]
                                        )
                                    )
                            case labelResult of
                                Left err -> pure (Left err)
                                Right labelOutput ->
                                    if shouldIgnoreAnnotationFailure labelOutput
                                        then pure (Right ())
                                        else
                                            case processExitCode labelOutput of
                                                ExitFailure _ -> pure (Left ("label " ++ resource ++ " failed: " ++ outputDetail labelOutput))
                                                ExitSuccess -> pure (Right ())

appendNamespaceArgs :: Maybe String -> [String] -> [String]
appendNamespaceArgs Nothing args = args
appendNamespaceArgs (Just namespace) args = args ++ ["-n", namespace]

selectorArgs :: Maybe String -> [String]
selectorArgs Nothing = []
selectorArgs (Just selector) = ["-l", selector]

runEitherActions :: [IO (Either String ())] -> IO (Either String ())
runEitherActions =
    foldM
        ( \result action ->
            case result of
                Left err -> pure (Left err)
                Right () -> action
        )
        (Right ())

parseObjectNames :: String -> [String]
parseObjectNames stdoutText =
    [ line
    | rawLine <- lines stdoutText,
      let line = trimTrailingNewlines rawLine,
      line /= "",
      '/' `elem` line
    ]

dropResourcePrefix :: String -> String
dropResourcePrefix value =
    case break (== '/') value of
        (_, "") -> value
        (_, '/' : suffix) -> suffix
        _ -> value

shouldIgnoreAnnotationFailure :: ProcessOutput -> Bool
shouldIgnoreAnnotationFailure output =
    case processExitCode output of
        ExitSuccess -> False
        ExitFailure _ ->
            let detail = outputDetail output
             in isNotFoundMessage detail || isIgnorableAnnotationError detail

isNotFoundMessage :: String -> Bool
isNotFoundMessage detail =
    let lowered = map toLower detail
     in "notfound" `isInfixOf` lowered || "not found" `isInfixOf` lowered

isIgnorableListingError :: String -> Bool
isIgnorableListingError detail =
    let lowered = map toLower detail
     in "the server doesn't have a resource type" `isInfixOf` lowered
            || "unable to list" `isInfixOf` lowered
            || "forbidden" `isInfixOf` lowered

isIgnorableAnnotationError :: String -> Bool
isIgnorableAnnotationError detail =
    let lowered = map toLower detail
     in "does not allow this method" `isInfixOf` lowered
            || "methodnotallowed" `isInfixOf` lowered

nonEmptyLines :: String -> [String]
nonEmptyLines =
    filter (/= "") . map trimTrailingNewlines . lines

captureKubectl :: FilePath -> [String] -> IO (Either String ProcessOutput)
captureKubectl repoRoot arguments = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "kubectl",
                  commandArguments = arguments,
                  commandEnvironment = Nothing,
                  commandWorkingDirectory = Just repoRoot
                }
    pure $
        case result of
            Failure err -> Left ("failed to start kubectl: " ++ err)
            Success output -> Right output

withTemporaryJsonFile :: String -> BL.ByteString -> (FilePath -> IO ExitCode) -> IO ExitCode
withTemporaryJsonFile prefix contents action = do
    temporaryDirectory <- getTemporaryDirectory
    bracket
        (do
            (path, handle) <- openTempFile temporaryDirectory prefix
            hClose handle
            BL.writeFile path contents
            pure path
        )
        (\path -> do
            _ <- try (removeFile path) :: IO (Either IOException ())
            pure ()
        )
        action

pulumiEnvironment :: FilePath -> ValidatedSettings -> IO (Either String [(String, String)])
pulumiEnvironment repoRoot settings = do
    currentEnvironment <- getEnvironment
    let backendDir = repoRoot </> ".pulumi-backend"
        baseEnvironment = awsCliEnvironment currentEnvironment (aws (validatedConfig settings))
        withBackend =
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
    createDirectoryIfMissing True backendDir
    prodboxIdResult <- resolveProdboxId
    pure (fmap (\prodboxId -> upsertEnv "PRODBOX_ID" prodboxId withPassphrase) prodboxIdResult)

resolveProdboxId :: IO (Either String String)
resolveProdboxId = fmap (fmap snd) resolveMachineIdentity

resolveMachineIdentity :: IO (Either String (String, String))
resolveMachineIdentity = do
    machineIdResult <- try (readFile "/etc/machine-id") :: IO (Either IOException String)
    pure $
        case machineIdResult of
            Left err -> Left ("failed to read /etc/machine-id: " ++ displayException err)
            Right rawMachineId ->
                case trimTrailingNewlines rawMachineId of
                    "" -> Left "/etc/machine-id is empty"
                    machineId -> Right (machineId, "prodbox-" ++ machineId)

prodboxIdToLabelValue :: String -> String
prodboxIdToLabelValue = take 63

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

runCommand :: CommandSpec -> IO ExitCode
runCommand spec = do
    result <- runStreamingCommand spec
    case result of
        Failure err -> failWith err
        Success exitCode -> pure exitCode

outputDetail :: ProcessOutput -> String
outputDetail output =
    case filter (/= "") [trimTrailingNewlines (processStderr output), trimTrailingNewlines (processStdout output)] of
        [] -> "subprocess exited without output"
        rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

trimTrailingNewlines :: String -> String
trimTrailingNewlines = reverse . dropWhile (\character -> character == '\n' || character == '\r') . reverse

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv key value environment = (key, value) : filter ((/= key) . fst) environment

removeEnv :: String -> [(String, String)] -> [(String, String)]
removeEnv key = filter ((/= key) . fst)

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
