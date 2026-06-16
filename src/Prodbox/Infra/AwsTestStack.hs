{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsTestStack
  ( AwsTestNode (..)
  , AwsTestStackSnapshot (..)
  , awsTestStackName
  , ensureAwsTestStackResources
  , destroyAwsTestStack
  , awsTestStackResidueStatus
  , assertNoAwsTestStackResidue
  , renderAwsTestStackReport
  , withAwsTestSshPrivateKey
  , parseAwsTestNodesFromOutputs
  , parseAwsTestStackFromOutputs
  )
where

import Control.Exception (IOException, bracket, catch)
import Control.Monad (foldM, forM, when)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiUpper, toLower)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Error (fatalError)
import Prodbox.Http.Client
  ( defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import Prodbox.Infra.AwsProviderCredentials qualified as AwsProviderCredentials
import Prodbox.Infra.MinioBackend
  ( bucketObjectCount
  , ensureMinioBackendBucket
  , pulumiBackendLoginTimeoutSeconds
  , pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Infra.StackOutputs qualified as StackOutputs
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Pulumi.EncryptedBackend
  ( LegacyPulumiBackend (..)
  , PulumiStackRef (..)
  , renderEncryptedBackendError
  , withMigratedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( Credentials (..)
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import System.Directory
  ( doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hPutStr, openTempFile)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)

awsTestStackName :: String
awsTestStackName = "aws-test"

awsTestPulumiStackRef :: PulumiStackRef
awsTestPulumiStackRef =
  PulumiStackRef "prodbox-aws-test" (Text.pack awsTestStackName)

awsTestPulumiProjectDir :: FilePath -> FilePath
awsTestPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-test"

-- | Sprint 4.16 typed residue status. Delegates to the live
-- @pulumi stack ls --json@ source-of-truth query through
-- 'Prodbox.Lifecycle.LiveResidue'; callers that need all three
-- per-run statuses should call 'queryPerRunResidueStatuses' directly
-- to share the MinIO port-forward bracket.
awsTestStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsTestStackResidueStatus repoRoot =
  LiveResidue.perRunAwsTest <$> LiveResidue.queryPerRunResidueStatuses repoRoot

data AwsTestNode = AwsTestNode
  { testNodeName :: String
  , testNodeAvailabilityZone :: String
  , testNodeInstanceId :: String
  , testNodePrivateIp :: String
  , testNodePublicIp :: String
  }
  deriving (Eq, Show)

data AwsTestStackSnapshot = AwsTestStackSnapshot
  { testSnapshotStackName :: String
  , testSnapshotBackendBucket :: String
  , testSnapshotVpcId :: String
  , testSnapshotSubnetIds :: [String]
  , testSnapshotSecurityGroupId :: String
  , testSnapshotNodes :: [AwsTestNode]
  }
  deriving (Eq, Show)

newtype AwsTestStackConfig = AwsTestStackConfig
  { testStackOperatorCidr :: String
  }
  deriving (Eq, Show)

-- | Sprint 4.18 sixth chunk: materialize the Pulumi-owned @aws-test@
-- SSH private key into a scoped temp file (chmod 600), hand the path
-- to the action, then clean up on exit. Replaces the legacy host-side
-- @ssh-keygen@ + @.prodbox-state\/aws-test\/id_ed25519@ persistent
-- file. The keypair now lives entirely in the Pulumi stack state: the
-- @aws-test@ Pulumi program declares a @tls:PrivateKey@ resource and
-- exports the private key as @ssh_private_key@ (secret-protected).
--
-- Throws via 'error' when:
--
--   * the live MinIO backend has no @aws-test@ snapshot to read, or
--   * the @ssh_private_key@ output is missing / empty.
--
-- The bracket guarantees the temp file is removed on all exit paths
-- including async exceptions in the action.
withAwsTestSshPrivateKey :: FilePath -> (FilePath -> IO a) -> IO a
withAwsTestSshPrivateKey repoRoot action = do
  outputsResult <-
    LiveResidue.fetchPerRunStackOutputs
      repoRoot
      (StackOutputs.StackName (Text.pack awsTestStackName))
  outputs <- case outputsResult of
    Left err ->
      error
        ( "withAwsTestSshPrivateKey: aws-test Pulumi outputs unavailable from the live MinIO backend: "
            ++ err
        )
    Right o -> pure o
  privateKey <- case Map.lookup (Text.pack "ssh_private_key") outputs of
    Nothing ->
      error
        "withAwsTestSshPrivateKey: aws-test Pulumi outputs missing required field 'ssh_private_key'"
    Just text ->
      let s = Text.unpack text
       in if null s
            then
              error
                "withAwsTestSshPrivateKey: aws-test Pulumi outputs field 'ssh_private_key' is empty"
            else pure s
  systemTemp <- getTemporaryDirectory
  bracket
    (openTempFile systemTemp "prodbox-aws-test-ssh-key-")
    ( \(path, handle) -> do
        hClose handle `catch` \(_ :: IOException) -> pure ()
        removeFile path `catch` \(_ :: IOException) -> pure ()
    )
    ( \(tempPath, handle) -> do
        hPutStr handle privateKey
        when (not (null privateKey) && last privateKey /= '\n') (hPutStr handle "\n")
        hClose handle
        setFileMode tempPath (unionFileModes ownerReadMode ownerWriteMode)
        action tempPath
    )

nodeFromJson :: Value -> Either String AwsTestNode
nodeFromJson (Object obj) = do
  name <- requireString obj "name"
  az <- requireString obj "availability_zone"
  instanceId <- requireString obj "instance_id"
  privateIp <- requireString obj "private_ip"
  publicIp <- requireString obj "public_ip"
  Right
    AwsTestNode
      { testNodeName = name
      , testNodeAvailabilityZone = az
      , testNodeInstanceId = instanceId
      , testNodePrivateIp = privateIp
      , testNodePublicIp = publicIp
      }
nodeFromJson _ = Left "node must be a JSON object"

-- | Sprint 4.18: decode the @nodes@ Pulumi output (a JSON-encoded
-- array of node objects) from the live @aws-test@ stack outputs map
-- returned by 'Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs'.
-- Replaces the legacy @.prodbox-state/aws-test/stack-snapshot.json@
-- file-IO path on the test-validation surface.
parseAwsTestNodesFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String [AwsTestNode]
parseAwsTestNodesFromOutputs outputs =
  case Map.lookup (Text.pack "nodes") outputs of
    Nothing -> Left "aws-test Pulumi outputs missing required field 'nodes'"
    Just rawText ->
      case eitherDecode (BL8.pack (Text.unpack rawText)) of
        Left err -> Left ("aws-test Pulumi output 'nodes' is not valid JSON: " ++ err)
        Right (Array arr) -> mapM nodeFromJson (Vector.toList arr)
        Right _ -> Left "aws-test Pulumi output 'nodes' must be a JSON array"

-- | Sprint 4.18: decode a full 'AwsTestStackSnapshot' from the live
-- @Map Text Text@ outputs returned by
-- 'Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs'. Mirrors the
-- ensure-path 'snapshotFromOutputs' but reads the flat map shape where
-- complex outputs (@subnet_ids@, @nodes@) arrive as JSON-encoded
-- strings. Replaces the legacy file-snapshot read in the destroy and
-- residue-assertion paths.
parseAwsTestStackFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String AwsTestStackSnapshot
parseAwsTestStackFromOutputs outputs = do
  backendBucket <- requireMapString outputs "backend_bucket"
  vpcId <- requireMapString outputs "vpc_id"
  subnetIds <- requireMapStringList outputs "subnet_ids"
  securityGroupId <- requireMapString outputs "security_group_id"
  nodes <- parseAwsTestNodesFromOutputs outputs
  Right
    AwsTestStackSnapshot
      { testSnapshotStackName = awsTestStackName
      , testSnapshotBackendBucket = backendBucket
      , testSnapshotVpcId = vpcId
      , testSnapshotSubnetIds = subnetIds
      , testSnapshotSecurityGroupId = securityGroupId
      , testSnapshotNodes = nodes
      }

-- | Sprint 4.18: live source-of-truth read of the @aws-test@ stack's
-- snapshot from the in-cluster MinIO Pulumi backend. Returns 'Nothing'
-- when the stack is absent, the backend is unreachable, or the outputs
-- cannot be parsed — matching the @Maybe@ contract the destroy and
-- residue-assertion paths previously got from the file cache, so the
-- absent path falls back to the tag-based residue scan as before.
fetchAwsTestSnapshotFromBackend :: FilePath -> IO (Maybe AwsTestStackSnapshot)
fetchAwsTestSnapshotFromBackend repoRoot = do
  outputsResult <-
    LiveResidue.fetchPerRunStackOutputs
      repoRoot
      (StackOutputs.StackName (Text.pack awsTestStackName))
  pure $ case outputsResult of
    Left _ -> Nothing
    Right outputs -> either (const Nothing) Just (parseAwsTestStackFromOutputs outputs)

requireMapString :: Map.Map Text.Text Text.Text -> String -> Either String String
requireMapString outputs key =
  case Map.lookup (Text.pack key) outputs of
    Nothing -> Left ("aws-test Pulumi outputs missing required field '" ++ key ++ "'")
    Just text ->
      let s = Text.unpack text
       in if null s then Left ("aws-test Pulumi output '" ++ key ++ "' is empty") else Right s

requireMapStringList :: Map.Map Text.Text Text.Text -> String -> Either String [String]
requireMapStringList outputs key =
  case Map.lookup (Text.pack key) outputs of
    Nothing -> Left ("aws-test Pulumi outputs missing required field '" ++ key ++ "'")
    Just text ->
      case eitherDecode (BL8.pack (Text.unpack text)) of
        Left err -> Left ("aws-test Pulumi output '" ++ key ++ "' is not valid JSON: " ++ err)
        Right (Array arr) -> mapM (mapEntryString key) (Vector.toList arr)
        Right _ -> Left ("aws-test Pulumi output '" ++ key ++ "' must be a JSON array")
 where
  mapEntryString k v = case v of
    String t ->
      let s = Text.unpack t
       in if null s then Left ("aws-test Pulumi output '" ++ k ++ "' contains an empty string") else Right s
    _ -> Left ("aws-test Pulumi output '" ++ k ++ "' must contain strings only")

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
      mapM (requireStringListEntry key) (Vector.toList arr)
    _ -> Left ("missing list output " ++ key)

requireStringListEntry :: String -> Value -> Either String String
requireStringListEntry key value =
  case value of
    String text ->
      let str = Text.unpack text
       in if null str then Left ("output " ++ key ++ " contains empty string") else Right str
    _ -> Left ("output " ++ key ++ " must contain strings only")

requireNodeList :: KeyMap.KeyMap Value -> String -> Either String [AwsTestNode]
requireNodeList obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (Array arr) -> mapM nodeFromJson (Vector.toList arr)
    _ -> Left ("missing node list " ++ key)

renderAwsTestStackReport :: AwsTestStackSnapshot -> Int -> String
renderAwsTestStackReport snapshot objectCount =
  unlines
    ( [ "STACK=" ++ testSnapshotStackName snapshot
      , "BACKEND_BUCKET=" ++ testSnapshotBackendBucket snapshot
      , "BACKEND_OBJECT_COUNT=" ++ show objectCount
      , "VPC_ID=" ++ testSnapshotVpcId snapshot
      , "SUBNET_IDS=" ++ joinComma (testSnapshotSubnetIds snapshot)
      , "SECURITY_GROUP_ID=" ++ testSnapshotSecurityGroupId snapshot
      , "NODE_COUNT=" ++ show (length (testSnapshotNodes snapshot))
      ]
        ++ concatMap renderNodeReport (zip [0 ..] (testSnapshotNodes snapshot))
    )

renderNodeReport :: (Int, AwsTestNode) -> [String]
renderNodeReport (index, node) =
  [ "NODE_" ++ show index ++ "_NAME=" ++ testNodeName node
  , "NODE_" ++ show index ++ "_AZ=" ++ testNodeAvailabilityZone node
  , "NODE_" ++ show index ++ "_INSTANCE_ID=" ++ testNodeInstanceId node
  , "NODE_" ++ show index ++ "_PRIVATE_IP=" ++ testNodePrivateIp node
  , "NODE_" ++ show index ++ "_PUBLIC_IP=" ++ testNodePublicIp node
  ]

settingsAwsEnv :: FilePath -> IO (Either String [(String, String)])
settingsAwsEnv repoRoot = do
  credentialsResult <- AwsProviderCredentials.loadPulumiProviderCredentials repoRoot
  case credentialsResult of
    Left err -> pure (Left err)
    Right credentials -> do
      baseEnv <- getEnvironment
      pure (Right (overlayAwsCredentials baseEnv credentials))

fetchPublicIpv4 :: IO (Either String String)
fetchPublicIpv4 = do
  result <- httpGetText defaultHttpConfig "https://api.ipify.org"
  case result of
    Left err -> pure (Left ("failed to fetch public IP: " ++ renderHttpError err))
    Right body ->
      let ip = trim body
       in if length (filter (== '.') ip) == 3
            then pure (Right ip)
            else pure (Left ("unexpected public IP response: " ++ ip))

pulumiProviderBaseEnv :: FilePath -> IO (Either String [(String, String)])
pulumiProviderBaseEnv repoRoot = do
  credentialsResult <- AwsProviderCredentials.loadPulumiProviderCredentials repoRoot
  case credentialsResult of
    Left err -> pure (Left err)
    Right providerCredentials -> do
      currentEnv <- getEnvironment
      let path = maybe "" id (lookup "PATH" currentEnv)
          home = maybe "" id (lookup "HOME" currentEnv)
          providerEnv = pulumiAwsProviderEnv providerCredentials
      pure
        ( Right
            ( [ ("AWS_EC2_METADATA_DISABLED", "true")
              , ("PULUMI_SKIP_UPDATE_CHECK", "true")
              , ("PATH", path)
              , ("HOME", home)
              , ("LANG", "C.UTF-8")
              ]
                ++ providerEnv
            )
        )

-- | Legacy raw MinIO backend environment used only for first-touch
-- checkpoint import/delete through 'LegacyPulumiBackend'. Supported
-- Pulumi actions receive 'pulumiProviderBaseEnv' and then have
-- @PULUMI_BACKEND_URL@ rewritten to a scratch @file://@ backend by
-- 'withMigratedDecryptedStackEnvironment'.
pulumiBackendBaseEnv :: Int -> String -> String -> IO [(String, String)]
pulumiBackendBaseEnv localPort minioAccessKey minioSecretKey = do
  currentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" currentEnv)
      home = maybe "" id (lookup "HOME" currentEnv)
  pure
    [ ("AWS_ACCESS_KEY_ID", minioAccessKey)
    , ("AWS_SECRET_ACCESS_KEY", minioSecretKey)
    , ("AWS_REGION", "us-east-1")
    , ("AWS_DEFAULT_REGION", "us-east-1")
    , ("AWS_EC2_METADATA_DISABLED", "true")
    , ("PULUMI_BACKEND_URL", pulumiBackendUrl localPort)
    , ("PULUMI_CONFIG_PASSPHRASE", "")
    , ("PULUMI_SKIP_UPDATE_CHECK", "true")
    , ("PATH", path)
    , ("HOME", home)
    , ("LANG", "C.UTF-8")
    ]

pulumiAwsProviderEnv :: Credentials -> [(String, String)]
pulumiAwsProviderEnv creds =
  baseEntries
    ++ case session_token creds of
      Just token -> [("PRODBOX_PULUMI_AWS_SESSION_TOKEN", Text.unpack token)]
      Nothing -> []
 where
  baseEntries =
    [ ("PRODBOX_PULUMI_AWS_ACCESS_KEY_ID", Text.unpack (access_key_id creds))
    , ("PRODBOX_PULUMI_AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key creds))
    , ("PRODBOX_PULUMI_AWS_REGION", Text.unpack (region creds))
    , ("PRODBOX_PULUMI_AWS_DEFAULT_REGION", Text.unpack (region creds))
    ]

-- | Resolve Vault-backed AWS provider credentials for the @aws-test@
-- Pulumi destroy path. Supported Pulumi stack operations fail closed when
-- @secret/gateway/gateway/aws@ is absent instead of falling back to raw
-- Dhall credentials.
loadOperationalAwsCredentials :: FilePath -> IO (Either String Credentials)
loadOperationalAwsCredentials =
  AwsProviderCredentials.loadPulumiProviderCredentials

runEnsureAwsTestPulumiCycle
  :: FilePath
  -> AwsTestStackConfig
  -> Int
  -> String
  -> String
  -> [(String, String)]
  -> IO (Either String ())
runEnsureAwsTestPulumiCycle projectDir stackConfig localPort accessKey secretKey environment = do
  loginExit <- pulumiLogin projectDir environment
  case loginExit of
    ExitFailure _ -> pure (Left "pulumi login failed")
    ExitSuccess -> do
      selectExit <- pulumiStackSelect projectDir environment True
      case selectExit of
        PulumiStackSelected -> do
          syncExit <- syncAwsTestStackConfig projectDir environment stackConfig
          case syncExit of
            ExitFailure _ -> pure (Left "pulumi config set failed")
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
                          objectCountResult <- bucketObjectCount localPort accessKey secretKey
                          case objectCountResult of
                            Left err -> pure (Left err)
                            Right objectCount -> do
                              writeOutput (renderAwsTestStackReport snapshot objectCount)
                              pure (Right ())
        PulumiStackMissing ->
          pure (Left "pulumi stack select reported a missing stack after --create")
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))

resolveAwsTestStackConfig :: FilePath -> IO (Either String AwsTestStackConfig)
resolveAwsTestStackConfig _repoRoot = do
  publicIpResult <- fetchPublicIpv4
  case publicIpResult of
    Left err -> pure (Left err)
    Right publicIp ->
      pure
        ( Right
            AwsTestStackConfig
              { testStackOperatorCidr = publicIp ++ "/32"
              }
        )

-- | Sprint 4.18 sixth chunk: @publicKey@ is no longer a config input —
-- the Pulumi stack owns the keypair via a @tls:PrivateKey@ resource and
-- exposes @ssh_private_key@ as a secret output.
syncAwsTestStackConfig :: FilePath -> [(String, String)] -> AwsTestStackConfig -> IO ExitCode
syncAwsTestStackConfig projectDir environment stackConfig =
  foldM runConfigSet ExitSuccess configEntries
 where
  configEntries =
    [ (False, "operatorCidr", testStackOperatorCidr stackConfig)
    ]

  runConfigSet :: ExitCode -> (Bool, String, String) -> IO ExitCode
  runConfigSet failure@(ExitFailure _) _ = pure failure
  runConfigSet ExitSuccess (secretValue, key, value) =
    runPulumiCommand
      projectDir
      environment
      ( ["config", "set", "--stack", awsTestStackName]
          ++ ["--secret" | secretValue]
          ++ [key, value]
      )

pulumiLogin :: FilePath -> [(String, String)] -> IO ExitCode
pulumiLogin projectDir environment = do
  loginResult <- pulumiLoginQuiet projectDir environment
  case loginResult of
    Right () -> pure ExitSuccess
    Left err -> do
      writeDiagnosticLine ("pulumi login failed: " ++ err)
      pure (ExitFailure 1)

pulumiLoginQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiLoginQuiet projectDir environment =
  runPulumiCommandQuiet
    projectDir
    environment
    ["login", maybe "" id (lookup "PULUMI_BACKEND_URL" environment)]

data PulumiStackSelectResult
  = PulumiStackSelected
  | PulumiStackMissing
  | PulumiStackSelectFailed String

pulumiStackSelect :: FilePath -> [(String, String)] -> Bool -> IO PulumiStackSelectResult
pulumiStackSelect projectDir environment createIfMissing =
  let arguments =
        ["stack", "select", awsTestStackName]
          ++ ["--create" | createIfMissing]
          ++ if createIfMissing then ["--secrets-provider", "plaintext"] else []
   in if createIfMissing
        then do
          exitCode <- runPulumiCommand projectDir environment arguments
          pure $
            case exitCode of
              ExitSuccess -> PulumiStackSelected
              ExitFailure _ -> PulumiStackSelectFailed "pulumi stack select failed"
        else do
          result <-
            captureSubprocessResult
              Subprocess
                { subprocessPath = "pulumi"
                , subprocessArguments = arguments
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just projectDir
                }
          pure $
            case result of
              Failure err -> PulumiStackSelectFailed err
              Success output ->
                case processExitCode output of
                  ExitSuccess -> PulumiStackSelected
                  ExitFailure _
                    | isMissingPulumiStackError awsTestStackName (renderProcessDetail output) ->
                        PulumiStackMissing
                    | otherwise ->
                        PulumiStackSelectFailed (renderProcessDetail output)

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
  runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsTestStackName]

pulumiDestroyQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiDestroyQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["destroy", "--yes", "--stack", awsTestStackName]

pulumiRefreshQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiRefreshQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["refresh", "--yes", "--stack", awsTestStackName]

pulumiStackRemoveQuiet :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiStackRemoveQuiet projectDir environment force =
  runPulumiCommandQuiet
    projectDir
    environment
    (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsTestStackName])

pulumiLoginEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiLoginEither projectDir environment summary
  | summary = pulumiLoginQuiet projectDir environment
  | otherwise = exitToEither "pulumi login" <$> pulumiLogin projectDir environment

pulumiDestroyEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiDestroyEither projectDir environment summary
  | summary = pulumiDestroyQuiet projectDir environment
  | otherwise =
      exitToEither "pulumi destroy"
        <$> runPulumiCommand projectDir environment ["destroy", "--yes", "--stack", awsTestStackName]

pulumiRefreshEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiRefreshEither projectDir environment summary
  | summary = pulumiRefreshQuiet projectDir environment
  | otherwise =
      exitToEither "pulumi refresh"
        <$> runPulumiCommand projectDir environment ["refresh", "--yes", "--stack", awsTestStackName]

pulumiStackRemoveEither :: FilePath -> [(String, String)] -> Bool -> Bool -> IO (Either String ())
pulumiStackRemoveEither projectDir environment force summary
  | summary = pulumiStackRemoveQuiet projectDir environment force
  | otherwise =
      exitToEither "pulumi stack rm"
        <$> runPulumiCommand
          projectDir
          environment
          (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsTestStackName])

exitToEither :: String -> ExitCode -> Either String ()
exitToEither _ ExitSuccess = Right ()
exitToEither label (ExitFailure code) = Left (label ++ " exited with code " ++ show code)

pulumiStackOutputs :: FilePath -> [(String, String)] -> IO (Either String Value)
pulumiStackOutputs projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["stack", "output", "--json", "--stack", awsTestStackName]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
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
    runSubprocessStreaming
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  case result of
    Failure err -> do
      writeDiagnosticLine err
      pure (ExitFailure 1)
    Success exitCode -> pure exitCode

runPulumiCommandQuiet :: FilePath -> [(String, String)] -> [String] -> IO (Either String ())
runPulumiCommandQuiet projectDir environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath =
            if isPulumiLoginCommand arguments
              then "timeout"
              else "pulumi"
        , subprocessArguments =
            if isPulumiLoginCommand arguments
              then
                [ "--kill-after=10s"
                , show pulumiBackendLoginTimeoutSeconds
                , "pulumi"
                ]
                  ++ arguments
                  ++ ["--non-interactive"]
              else arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just projectDir
        }
  pure $
    case result of
      Failure err -> Left err
      Success output ->
        case processExitCode output of
          ExitSuccess -> Right ()
          ExitFailure 124
            | isPulumiLoginCommand arguments ->
                Left
                  ( "timed out after "
                      ++ show pulumiBackendLoginTimeoutSeconds
                      ++ " seconds while running `pulumi login` against the MinIO backend"
                  )
          ExitFailure _ -> Left (renderProcessDetail output)

isPulumiLoginCommand :: [String] -> Bool
isPulumiLoginCommand arguments =
  case arguments of
    "login" : _ -> True
    _ -> False

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
          { testSnapshotStackName = stackName
          , testSnapshotBackendBucket = backendBucket
          , testSnapshotVpcId = vpcId
          , testSnapshotSubnetIds = subnetIds
          , testSnapshotSecurityGroupId = securityGroupId
          , testSnapshotNodes = nodes
          }
snapshotFromOutputs _ = Left "pulumi output must be a JSON object"

resourceStillExists :: FilePath -> [String] -> IO (Either String Bool)
resourceStillExists repoRoot command =
  case command of
    [] -> pure (Left "resource existence check requires a command")
    subprocessPath : subprocessArguments -> do
      envResult <- settingsAwsEnv repoRoot
      case envResult of
        Left err -> pure (Left err)
        Right environment -> do
          result <-
            captureSubprocessResult
              Subprocess
                { subprocessPath = subprocessPath
                , subprocessArguments = subprocessArguments
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Nothing
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

instanceStillExists :: FilePath -> String -> IO (Either String Bool)
instanceStillExists repoRoot instanceId = do
  envResult <- settingsAwsEnv repoRoot
  case envResult of
    Left err -> pure (Left err)
    Right environment -> do
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                ["ec2", "describe-instances", "--instance-ids", instanceId, "--output", "json"]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Nothing
            }
      case result of
        Failure err -> pure (Left err)
        Success output ->
          case processExitCode output of
            ExitFailure _ ->
              let detail = trim (processStderr output) ++ " " ++ trim (processStdout output)
               in if isResourceMissing detail
                    then pure (Right False)
                    else
                      pure (Left ("aws ec2 describe-instances --instance-ids " ++ instanceId ++ " failed: " ++ detail))
            ExitSuccess ->
              case eitherDecode (BL8.pack (processStdout output)) of
                Left err -> pure (Left ("failed to parse EC2 instance JSON: " ++ err))
                Right payload -> pure (instanceDescribeShowsActiveInstance payload)

isResourceMissing :: String -> Bool
isResourceMissing detail =
  let lowered = map toLowerAscii detail
   in any
        (`isSubstring` lowered)
        [ "notfound"
        , "not found"
        , "does not exist"
        , "invalidgroup.notfound"
        , "invalidsubnetid.notfound"
        , "invalidvpcid.notfound"
        , "invalidinstanceid.notfound"
        , "nokeypair"
        , "nosuchentity"
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
  | isAsciiUpper c = toEnum (fromEnum c + 32)
  | otherwise = c

assertNoAwsTestStackResidue :: FilePath -> Maybe AwsTestStackSnapshot -> IO (Either String ())
assertNoAwsTestStackResidue repoRoot maybeSnapshot = do
  snapshot <- case maybeSnapshot of
    Just s -> pure (Just s)
    Nothing -> fetchAwsTestSnapshotFromBackend repoRoot
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
  vpcResult <-
    resourceStillExists
      repoRoot
      ["aws", "ec2", "describe-vpcs", "--vpc-ids", testSnapshotVpcId snapshot]
  case vpcResult of
    Left err -> pure (Left err)
    Right _vpcExists -> do
      subnetResults <- forM (testSnapshotSubnetIds snapshot) $ \subnetId ->
        resourceStillExists repoRoot ["aws", "ec2", "describe-subnets", "--subnet-ids", subnetId]
      sgResult <-
        resourceStillExists
          repoRoot
          ["aws", "ec2", "describe-security-groups", "--group-ids", testSnapshotSecurityGroupId snapshot]
      instanceResults <- forM (testSnapshotNodes snapshot) $ \node ->
        instanceStillExists repoRoot (testNodeInstanceId node)
      let allResults =
            [("vpc=" ++ testSnapshotVpcId snapshot, vpcResult)]
              ++ zipWith (\sid r -> ("subnet=" ++ sid, r)) (testSnapshotSubnetIds snapshot) subnetResults
              ++ [("security-group=" ++ testSnapshotSecurityGroupId snapshot, sgResult)]
              ++ zipWith
                (\n r -> ("instance=" ++ testNodeInstanceId n, r))
                (testSnapshotNodes snapshot)
                instanceResults
      case mapM snd allResults of
        Left err -> pure (Left err)
        Right existsList ->
          pure (Right [label | (label, True) <- zip (map fst allResults) existsList])

instanceDescribeShowsActiveInstance :: Value -> Either String Bool
instanceDescribeShowsActiveInstance (Object obj) =
  case KeyMap.lookup (Key.fromString "Reservations") obj of
    Just (Array reservations) ->
      fmap or (mapM reservationHasActiveInstance (Vector.toList reservations))
    _ -> Left "describe-instances response missing Reservations array"
 where
  reservationHasActiveInstance :: Value -> Either String Bool
  reservationHasActiveInstance (Object reservationObj) =
    case KeyMap.lookup (Key.fromString "Instances") reservationObj of
      Just (Array instancesArray) ->
        fmap or (mapM instanceIsActive (Vector.toList instancesArray))
      _ -> Left "describe-instances reservation missing Instances array"
  reservationHasActiveInstance _ = Left "describe-instances reservation must be an object"

  instanceIsActive :: Value -> Either String Bool
  instanceIsActive (Object instanceObj) =
    case KeyMap.lookup (Key.fromString "State") instanceObj of
      Just (Object stateObj) ->
        case KeyMap.lookup (Key.fromString "Name") stateObj of
          Just (String stateName) ->
            pure (Text.unpack stateName /= "terminated")
          _ -> Left "describe-instances state missing Name"
      _ -> Left "describe-instances instance missing State object"
  instanceIsActive _ = Left "describe-instances instance must be an object"
instanceDescribeShowsActiveInstance _ = Left "describe-instances response must be a JSON object"

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
                configResult <- resolveAwsTestStackConfig repoRoot
                case configResult of
                  Left err -> pure (Left err)
                  Right stackConfig -> do
                    providerEnvironmentResult <- pulumiProviderBaseEnv repoRoot
                    case providerEnvironmentResult of
                      Left err -> pure (Left err)
                      Right providerEnvironment -> do
                        legacyEnvironment <- pulumiBackendBaseEnv localPort accessKey secretKey
                        backendResult <-
                          withMigratedDecryptedStackEnvironment
                            repoRoot
                            awsTestPulumiStackRef
                            (LegacyPulumiBackend projectDir legacyEnvironment (Text.pack awsTestStackName))
                            providerEnvironment
                            (runEnsureAwsTestPulumiCycle projectDir stackConfig localPort accessKey secretKey)
                        pure $ case backendResult of
                          Left err -> Left (renderEncryptedBackendError err)
                          Right () -> Right ()
      case portForwardResult of
        Left err -> failWith err
        Right (Left err) -> failWith err
        Right (Right ()) -> pure ExitSuccess

destroyAwsTestStack :: FilePath -> Bool -> IO ExitCode
destroyAwsTestStack repoRoot summary = do
  statusResult <- destroyAwsTestStackStatus repoRoot summary
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS test stack: " ++ status)
      pure ExitSuccess

runDestroyAwsTestPulumiCycle
  :: FilePath
  -> FilePath
  -> Maybe AwsTestStackSnapshot
  -> Bool
  -> [(String, String)]
  -> IO (Either String String)
runDestroyAwsTestPulumiCycle repoRoot projectDir currentSnapshot summary environment = do
  loginResult <- pulumiLoginEither projectDir environment summary
  case loginResult of
    Left err -> pure (Left ("pulumi login failed: " ++ err))
    Right () -> do
      selectExit <- pulumiStackSelect projectDir environment False
      case selectExit of
        PulumiStackSelected -> do
          operationalCredentialsResult <- loadOperationalAwsCredentials repoRoot
          case operationalCredentialsResult of
            Left err ->
              pure
                ( Left
                    ( "operational AWS credentials are required to destroy the AWS test stack once a Pulumi stack exists: "
                        ++ err
                    )
                )
            Right _operationalCredentials -> do
              configResult <- resolveAwsTestStackConfig repoRoot
              case configResult of
                Left err -> pure (Left err)
                Right stackConfig -> do
                  syncExit <- syncAwsTestStackConfig projectDir environment stackConfig
                  case syncExit of
                    ExitFailure _ -> pure (Left "pulumi config set failed")
                    ExitSuccess -> do
                      destroyResult <- pulumiDestroyEither projectDir environment summary
                      case destroyResult of
                        Left _ -> do
                          _ <- pulumiRefreshEither projectDir environment summary
                          retryResult <- pulumiDestroyEither projectDir environment summary
                          case retryResult of
                            Left err -> pure (Left ("pulumi destroy failed after refresh: " ++ err))
                            Right () -> completeDestroy repoRoot projectDir environment currentSnapshot summary
                        Right () ->
                          completeDestroy repoRoot projectDir environment currentSnapshot summary
        PulumiStackMissing ->
          case currentSnapshot of
            Nothing ->
              pure (Right ("already absent from the local Pulumi backend" :: String))
            Just _ -> finalizeDestroy repoRoot currentSnapshot
        PulumiStackSelectFailed detail ->
          pure (Left ("pulumi stack select failed: " ++ detail))

destroyAwsTestStackStatus :: FilePath -> Bool -> IO (Either String String)
destroyAwsTestStackStatus repoRoot summary = do
  currentSnapshot <- fetchAwsTestSnapshotFromBackend repoRoot
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
            providerEnvironmentResult <- pulumiProviderBaseEnv repoRoot
            case providerEnvironmentResult of
              Left err -> pure (Left err)
              Right providerEnvironment -> do
                legacyEnvironment <- pulumiBackendBaseEnv localPort accessKey secretKey
                backendResult <-
                  withMigratedDecryptedStackEnvironment
                    repoRoot
                    awsTestPulumiStackRef
                    (LegacyPulumiBackend projectDir legacyEnvironment (Text.pack awsTestStackName))
                    providerEnvironment
                    (runDestroyAwsTestPulumiCycle repoRoot projectDir currentSnapshot summary)
                pure $ case backendResult of
                  Left err -> Left (renderEncryptedBackendError err)
                  Right status -> Right status
  case portForwardResult of
    Left err ->
      case currentSnapshot of
        Nothing ->
          pure (Right "no local Pulumi backend or saved residue snapshot; nothing to destroy")
        Just _ ->
          pure
            (Left ("local MinIO backend unavailable while an AWS test stack snapshot still exists: " ++ err))
    Right (Left err) -> pure (Left err)
    Right (Right status) -> pure (Right status)

completeDestroy
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe AwsTestStackSnapshot
  -> Bool
  -> IO (Either String String)
completeDestroy repoRoot projectDir environment currentSnapshot summary = do
  _ <- pulumiStackRemoveEither projectDir environment False summary
  finalizeDestroy repoRoot currentSnapshot

finalizeDestroy :: FilePath -> Maybe AwsTestStackSnapshot -> IO (Either String String)
finalizeDestroy repoRoot currentSnapshot = do
  residueResult <- assertNoAwsTestStackResidue repoRoot currentSnapshot
  case residueResult of
    Left err -> pure (Left err)
    Right () -> pure (Right ("destroyed and residue check passed" :: String))

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

joinComma :: [String] -> String
joinComma [] = ""
joinComma items = foldr1 (\a b -> a ++ "," ++ b) items

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

isMissingPulumiStackError :: String -> String -> Bool
isMissingPulumiStackError stackName detail =
  let lowered = map toLower detail
      loweredStackName = map toLower stackName
   in "no stack named" `isInfixOf` lowered
        && loweredStackName `isInfixOf` lowered
        && "found" `isInfixOf` lowered
