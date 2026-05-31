{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Infra.AwsEksTestStack
  ( AwsEksTestStackSnapshot (..)
  , awsEksTestStackName
  , awsEksCanonicalClusterName
  , ensureAwsEksTestStackResources
  , destroyAwsEksTestStack
  , awsEksTestStackResidueStatus
  , withEksKubeconfig
  , assertNoAwsEksTestStackResidue
  , credentialsConfigured
  , loadOperationalAwsCredentials
  , pulumiAwsProviderEnv
  , pulumiBackendBaseEnv
  , settingsAwsEnv
  , renderAwsEksTestStackReport
  , parseAwsEksTestStackFromOutputs
  )
where

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
import Prodbox.Infra.MinioBackend
  ( bucketObjectCount
  , ensureMinioBackendBucket
  , pulumiBackendLoginTimeoutSeconds
  , pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Infra.StackOutputs qualified as StackOutputs
import Prodbox.Lifecycle.K8sDrain qualified as K8sDrain
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( Credentials (..)
  , ValidatedSettings (..)
  , aws
  , aws_admin_for_test_simulation
  , loadConfigFile
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Control.Exception (IOException, SomeException, bracket, catch, try)
import System.Directory
  ( doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

awsEksTestStackName :: String
awsEksTestStackName = "aws-eks-test"

awsEksTestPulumiProjectDir :: FilePath -> FilePath
awsEksTestPulumiProjectDir repoRoot = repoRoot </> "pulumi" </> "aws-eks"

-- | Sprint 4.16 typed residue status. Delegates to the live
-- @pulumi stack ls --json@ source-of-truth query through
-- 'Prodbox.Lifecycle.LiveResidue'; callers that need all three
-- per-run statuses should call 'queryPerRunResidueStatuses' directly
-- to share the MinIO port-forward bracket.
awsEksTestStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsEksTestStackResidueStatus repoRoot =
  LiveResidue.perRunAwsEksTest <$> LiveResidue.queryPerRunResidueStatuses repoRoot

awsEksCanonicalClusterName :: String
awsEksCanonicalClusterName = awsEksTestStackName ++ "-cluster"

awsEksCanonicalNodeGroupName :: String
awsEksCanonicalNodeGroupName = awsEksTestStackName ++ "-node-group"

awsEksCanonicalIgwTagName :: String
awsEksCanonicalIgwTagName = awsEksTestStackName ++ "-igw"

awsEksCanonicalPublicRouteTableTagName :: String
awsEksCanonicalPublicRouteTableTagName = awsEksTestStackName ++ "-public-rt"

data AwsEksTestStackSnapshot = AwsEksTestStackSnapshot
  { eksSnapshotStackName :: String
  , eksSnapshotBackendBucket :: String
  , eksSnapshotClusterName :: String
  , eksSnapshotClusterRoleName :: String
  , eksSnapshotNodeGroupName :: String
  , eksSnapshotNodeRoleName :: String
  , eksSnapshotVpcId :: String
  , eksSnapshotSubnetIds :: [String]
  , eksSnapshotClusterSecurityGroupId :: String
  , eksSnapshotClusterOidcIssuer :: String
  , eksSnapshotOidcProviderArn :: String
  , eksSnapshotAwsLbControllerPolicyArn :: String
  , eksSnapshotAwsLbControllerRoleArn :: String
  , eksSnapshotAwsLbControllerRoleName :: String
  }
  deriving (Eq, Show)

newtype AwsEksTestStackConfig = AwsEksTestStackConfig
  { eksStackOperatorCidr :: String
  }
  deriving (Eq, Show)

data AwsEksCanonicalResidue = AwsEksCanonicalResidue
  { canonicalResidueClusterRoleName :: String
  , canonicalResidueNodeRoleName :: Maybe String
  , canonicalResidueVpcId :: String
  , canonicalResidueSubnetIds :: [String]
  , canonicalResidueClusterSecurityGroupId :: String
  }
  deriving (Eq, Show)

-- | Sprint 4.18: live source-of-truth read of the @aws-eks-test@
-- stack snapshot from the in-cluster MinIO Pulumi backend. Returns
-- 'Nothing' when the stack is absent, the backend is unreachable, or
-- the outputs cannot be parsed — matching the @Maybe@ contract the
-- ensure pre-check, destroy, and residue-assertion paths previously
-- got from the file cache, so the absent path falls back to the
-- canonical tag-based residue scan as before.
fetchAwsEksTestSnapshotFromBackend :: FilePath -> IO (Maybe AwsEksTestStackSnapshot)
fetchAwsEksTestSnapshotFromBackend repoRoot = do
  outputsResult <-
    LiveResidue.fetchPerRunStackOutputs
      repoRoot
      (StackOutputs.StackName (Text.pack awsEksTestStackName))
  pure $ case outputsResult of
    Left _ -> Nothing
    Right outputs -> either (const Nothing) Just (parseAwsEksTestStackFromOutputs outputs)

snapshotFromOutputs :: Value -> Either String AwsEksTestStackSnapshot
snapshotFromOutputs (Object obj) = do
  backendBucket <- requireString obj "backend_bucket"
  clusterName <- requireString obj "cluster_name"
  clusterRoleName <- requireString obj "cluster_role_name"
  nodeGroupName <- requireString obj "node_group_name"
  nodeRoleName <- requireString obj "node_role_name"
  vpcId <- requireString obj "vpc_id"
  subnetIds <- requireStringList obj "subnet_ids"
  clusterSecurityGroupId <- requireString obj "cluster_security_group_id"
  clusterOidcIssuer <- requireString obj "cluster_oidc_issuer"
  oidcProviderArn <- requireString obj "oidc_provider_arn"
  awsLbControllerPolicyArn <- requireString obj "aws_lb_controller_policy_arn"
  awsLbControllerRoleArn <- requireString obj "aws_lb_controller_role_arn"
  awsLbControllerRoleName <- requireString obj "aws_lb_controller_role_name"
  Right
    AwsEksTestStackSnapshot
      { eksSnapshotStackName = awsEksTestStackName
      , eksSnapshotBackendBucket = backendBucket
      , eksSnapshotClusterName = clusterName
      , eksSnapshotClusterRoleName = clusterRoleName
      , eksSnapshotNodeGroupName = nodeGroupName
      , eksSnapshotNodeRoleName = nodeRoleName
      , eksSnapshotVpcId = vpcId
      , eksSnapshotSubnetIds = subnetIds
      , eksSnapshotClusterSecurityGroupId = clusterSecurityGroupId
      , eksSnapshotClusterOidcIssuer = clusterOidcIssuer
      , eksSnapshotOidcProviderArn = oidcProviderArn
      , eksSnapshotAwsLbControllerPolicyArn = awsLbControllerPolicyArn
      , eksSnapshotAwsLbControllerRoleArn = awsLbControllerRoleArn
      , eksSnapshotAwsLbControllerRoleName = awsLbControllerRoleName
      }
snapshotFromOutputs _ = Left "pulumi output must be a JSON object"

-- | Sprint 4.18: decode an 'AwsEksTestStackSnapshot' record directly
-- from the flat @Map Text Text@ returned by
-- 'Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs'. Replaces
-- the legacy @.prodbox-state\/aws-eks-test\/stack-snapshot.json@
-- file-IO consumer on the substrate-platform install path. Complex
-- outputs (e.g. @subnet_ids@) arrive as JSON-encoded strings and are
-- decoded back to their structured form here.
parseAwsEksTestStackFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String AwsEksTestStackSnapshot
parseAwsEksTestStackFromOutputs outputs = do
  backendBucket <- requireOutputString outputs "backend_bucket"
  clusterName <- requireOutputString outputs "cluster_name"
  clusterRoleName <- requireOutputString outputs "cluster_role_name"
  nodeGroupName <- requireOutputString outputs "node_group_name"
  nodeRoleName <- requireOutputString outputs "node_role_name"
  vpcId <- requireOutputString outputs "vpc_id"
  subnetIds <- requireOutputStringList outputs "subnet_ids"
  clusterSecurityGroupId <- requireOutputString outputs "cluster_security_group_id"
  clusterOidcIssuer <- requireOutputString outputs "cluster_oidc_issuer"
  oidcProviderArn <- requireOutputString outputs "oidc_provider_arn"
  awsLbControllerPolicyArn <- requireOutputString outputs "aws_lb_controller_policy_arn"
  awsLbControllerRoleArn <- requireOutputString outputs "aws_lb_controller_role_arn"
  awsLbControllerRoleName <- requireOutputString outputs "aws_lb_controller_role_name"
  Right
    AwsEksTestStackSnapshot
      { eksSnapshotStackName = awsEksTestStackName
      , eksSnapshotBackendBucket = backendBucket
      , eksSnapshotClusterName = clusterName
      , eksSnapshotClusterRoleName = clusterRoleName
      , eksSnapshotNodeGroupName = nodeGroupName
      , eksSnapshotNodeRoleName = nodeRoleName
      , eksSnapshotVpcId = vpcId
      , eksSnapshotSubnetIds = subnetIds
      , eksSnapshotClusterSecurityGroupId = clusterSecurityGroupId
      , eksSnapshotClusterOidcIssuer = clusterOidcIssuer
      , eksSnapshotOidcProviderArn = oidcProviderArn
      , eksSnapshotAwsLbControllerPolicyArn = awsLbControllerPolicyArn
      , eksSnapshotAwsLbControllerRoleArn = awsLbControllerRoleArn
      , eksSnapshotAwsLbControllerRoleName = awsLbControllerRoleName
      }

requireOutputString
  :: Map.Map Text.Text Text.Text -> Text.Text -> Either String String
requireOutputString outputs key =
  case Map.lookup key outputs of
    Nothing -> Left ("aws-eks-test Pulumi outputs missing required field '" ++ Text.unpack key ++ "'")
    Just text ->
      let s = Text.unpack text
       in if null s
            then Left ("aws-eks-test Pulumi output '" ++ Text.unpack key ++ "' is empty")
            else Right s

requireOutputStringList
  :: Map.Map Text.Text Text.Text -> Text.Text -> Either String [String]
requireOutputStringList outputs key =
  case Map.lookup key outputs of
    Nothing -> Left ("aws-eks-test Pulumi outputs missing required field '" ++ Text.unpack key ++ "'")
    Just text ->
      case eitherDecode (BL8.pack (Text.unpack text)) of
        Left err ->
          Left
            ( "aws-eks-test Pulumi output '"
                ++ Text.unpack key
                ++ "' is not valid JSON: "
                ++ err
            )
        Right (Array arr) -> mapM (asString key) (Vector.toList arr)
        Right _ ->
          Left
            ( "aws-eks-test Pulumi output '"
                ++ Text.unpack key
                ++ "' must be a JSON array"
            )
 where
  asString k v = case v of
    String t ->
      let s = Text.unpack t
       in if null s
            then Left ("aws-eks-test Pulumi output '" ++ Text.unpack k ++ "' contains an empty string")
            else Right s
    _ -> Left ("aws-eks-test Pulumi output '" ++ Text.unpack k ++ "' must contain strings only")

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

discoverCanonicalAwsEksResidue :: FilePath -> IO (Either String (Maybe AwsEksCanonicalResidue))
discoverCanonicalAwsEksResidue repoRoot = do
  clusterValueResult <-
    runAwsJsonCommandMaybeMissing
      repoRoot
      ["eks", "describe-cluster", "--name", awsEksCanonicalClusterName, "--output", "json"]
  case clusterValueResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just clusterValue) ->
      case parseCanonicalResidueFromCluster clusterValue of
        Left err -> pure (Left err)
        Right clusterResidue -> do
          nodeRoleResult <-
            runAwsJsonCommandMaybeMissing
              repoRoot
              [ "eks"
              , "describe-nodegroup"
              , "--cluster-name"
              , awsEksCanonicalClusterName
              , "--nodegroup-name"
              , awsEksCanonicalNodeGroupName
              , "--output"
              , "json"
              ]
          pure $
            case nodeRoleResult of
              Left err -> Left err
              Right Nothing -> Right (Just clusterResidue)
              Right (Just nodeGroupValue) ->
                case parseNodeRoleNameFromNodeGroup nodeGroupValue of
                  Left err -> Left err
                  Right nodeRoleName ->
                    Right
                      ( Just
                          clusterResidue
                            { canonicalResidueNodeRoleName = Just nodeRoleName
                            }
                      )

parseCanonicalResidueFromCluster :: Value -> Either String AwsEksCanonicalResidue
parseCanonicalResidueFromCluster (Object payload) = do
  clusterValue <- requireObjectValue payload "cluster"
  roleArn <- requireNestedString clusterValue ["roleArn"]
  vpcId <- requireNestedString clusterValue ["resourcesVpcConfig", "vpcId"]
  subnetIds <- requireNestedStringList clusterValue ["resourcesVpcConfig", "subnetIds"]
  clusterSecurityGroupId <-
    requireNestedString clusterValue ["resourcesVpcConfig", "clusterSecurityGroupId"]
  pure
    AwsEksCanonicalResidue
      { canonicalResidueClusterRoleName = roleNameFromArn roleArn
      , canonicalResidueNodeRoleName = Nothing
      , canonicalResidueVpcId = vpcId
      , canonicalResidueSubnetIds = subnetIds
      , canonicalResidueClusterSecurityGroupId = clusterSecurityGroupId
      }
parseCanonicalResidueFromCluster _ = Left "aws eks describe-cluster returned a non-object payload"

parseNodeRoleNameFromNodeGroup :: Value -> Either String String
parseNodeRoleNameFromNodeGroup (Object payload) = do
  nodeGroupValue <- requireObjectValue payload "nodegroup"
  roleArn <- requireNestedString nodeGroupValue ["nodeRole"]
  pure (roleNameFromArn roleArn)
parseNodeRoleNameFromNodeGroup _ = Left "aws eks describe-nodegroup returned a non-object payload"

requireObjectValue :: KeyMap.KeyMap Value -> String -> Either String Value
requireObjectValue payload key =
  case KeyMap.lookup (Key.fromString key) payload of
    Just value@(Object _) -> Right value
    _ -> Left ("missing object field " ++ key)

requireNestedString :: Value -> [String] -> Either String String
requireNestedString value [] =
  case value of
    String text ->
      let rendered = Text.unpack text
       in if null rendered then Left "encountered empty string field" else Right rendered
    _ -> Left "expected string field"
requireNestedString (Object payload) (field : fields) =
  case KeyMap.lookup (Key.fromString field) payload of
    Just nextValue -> requireNestedString nextValue fields
    Nothing -> Left ("missing nested field " ++ field)
requireNestedString _ _ = Left "expected nested object while decoding AWS EKS residue"

requireNestedStringList :: Value -> [String] -> Either String [String]
requireNestedStringList value [] =
  case value of
    Array entries ->
      mapM requireNestedStringListEntry (Vector.toList entries)
    _ -> Left "expected list field"
requireNestedStringList (Object payload) (field : fields) =
  case KeyMap.lookup (Key.fromString field) payload of
    Just nextValue -> requireNestedStringList nextValue fields
    Nothing -> Left ("missing nested list field " ++ field)
requireNestedStringList _ _ = Left "expected nested object while decoding AWS EKS list field"

requireNestedStringListEntry :: Value -> Either String String
requireNestedStringListEntry entry =
  case entry of
    String text ->
      let rendered = Text.unpack text
       in if null rendered then Left "encountered empty string inside list field" else Right rendered
    _ -> Left "expected string entries in list field"

roleNameFromArn :: String -> String
roleNameFromArn arn =
  reverse (takeWhile (/= '/') (reverse arn))

renderAwsEksTestStackReport :: AwsEksTestStackSnapshot -> Int -> String
renderAwsEksTestStackReport snapshot objectCount =
  unlines
    [ "STACK=" ++ eksSnapshotStackName snapshot
    , "BACKEND_BUCKET=" ++ eksSnapshotBackendBucket snapshot
    , "BACKEND_OBJECT_COUNT=" ++ show objectCount
    , "CLUSTER_NAME=" ++ eksSnapshotClusterName snapshot
    , "NODE_GROUP_NAME=" ++ eksSnapshotNodeGroupName snapshot
    , "CLUSTER_ROLE_NAME=" ++ eksSnapshotClusterRoleName snapshot
    , "NODE_ROLE_NAME=" ++ eksSnapshotNodeRoleName snapshot
    , "VPC_ID=" ++ eksSnapshotVpcId snapshot
    , "SUBNET_IDS=" ++ joinComma (eksSnapshotSubnetIds snapshot)
    , "CLUSTER_SECURITY_GROUP_ID=" ++ eksSnapshotClusterSecurityGroupId snapshot
    , "CLUSTER_OIDC_ISSUER=" ++ eksSnapshotClusterOidcIssuer snapshot
    , "OIDC_PROVIDER_ARN=" ++ eksSnapshotOidcProviderArn snapshot
    , "AWS_LB_CONTROLLER_POLICY_ARN=" ++ eksSnapshotAwsLbControllerPolicyArn snapshot
    , "AWS_LB_CONTROLLER_ROLE_ARN=" ++ eksSnapshotAwsLbControllerRoleArn snapshot
    , "AWS_LB_CONTROLLER_ROLE_NAME=" ++ eksSnapshotAwsLbControllerRoleName snapshot
    ]

settingsAwsEnv :: FilePath -> IO (Either String [(String, String)])
settingsAwsEnv repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left err)
    Right settings -> do
      baseEnv <- getEnvironment
      pure (Right (overlayAwsCredentials baseEnv (aws (validatedConfig settings))))

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

pulumiEksBaseEnv :: FilePath -> Int -> String -> String -> IO (Either String [(String, String)])
pulumiEksBaseEnv repoRoot localPort minioAccessKey minioSecretKey = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left err)
    Right settings -> do
      currentEnv <- getEnvironment
      let path = maybe "" id (lookup "PATH" currentEnv)
          home = maybe "" id (lookup "HOME" currentEnv)
          providerEnv = pulumiAwsProviderEnv (aws (validatedConfig settings))
      pure
        ( Right
            ( [ ("AWS_ACCESS_KEY_ID", minioAccessKey)
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
                ++ providerEnv
            )
        )

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

-- | Resolve AWS credentials for the @aws-eks-test@ Pulumi destroy path.
-- Tries operational @aws.*@ first, then falls back to admin
-- @aws_admin_for_test_simulation.*@ if operational is empty. The fallback
-- is the in-memory analog of the @withMaterializedOperationalCreds@
-- bracket from [Lifecycle Reconciliation Doctrine §5b]
-- (../../documents/engineering/lifecycle_reconciliation_doctrine.md):
-- it closes the cascade-credentials failure class observed on May 22,
-- 2026 by keeping the destroy path working when the harness teardown
-- cleared @aws.*@ before the per-run stack was destroyed. No file
-- mutation; the bracket-style restore semantics from the doctrine apply
-- to harness setup/teardown, not to the read-side credential lookup
-- here.
loadOperationalAwsCredentials :: FilePath -> IO (Either String Credentials)
loadOperationalAwsCredentials repoRoot = do
  configResult <- loadConfigFile repoRoot
  pure $
    case configResult of
      Left err -> Left err
      Right config ->
        let operational = aws config
            adminFallback = aws_admin_for_test_simulation config
         in if credentialsConfigured operational
              then Right operational
              else
                if credentialsConfigured adminFallback
                  then Right adminFallback
                  else
                    Left
                      "aws.access_key_id must not be empty (operational \
                      \aws.* unset and aws_admin_for_test_simulation.* \
                      \fallback also empty)"

credentialsConfigured :: Credentials -> Bool
credentialsConfigured creds =
  not (Text.null (Text.strip (access_key_id creds)))
    && not (Text.null (Text.strip (secret_access_key creds)))
    && not (Text.null (Text.strip (region creds)))

resolveAwsEksTestStackConfig :: IO (Either String AwsEksTestStackConfig)
resolveAwsEksTestStackConfig = do
  publicIpResult <- fetchPublicIpv4
  case publicIpResult of
    Left err -> pure (Left err)
    Right publicIp ->
      pure
        ( Right
            AwsEksTestStackConfig
              { eksStackOperatorCidr = publicIp ++ "/32"
              }
        )

syncAwsEksTestStackConfig :: FilePath -> [(String, String)] -> AwsEksTestStackConfig -> IO ExitCode
syncAwsEksTestStackConfig projectDir environment stackConfig =
  foldM runConfigSet ExitSuccess configEntries
 where
  configEntries = [(False, "operatorCidr", eksStackOperatorCidr stackConfig)]

  runConfigSet :: ExitCode -> (Bool, String, String) -> IO ExitCode
  runConfigSet failure@(ExitFailure _) _ = pure failure
  runConfigSet ExitSuccess (secretValue, key, value) =
    runPulumiCommand
      projectDir
      environment
      ( ["config", "set", "--stack", awsEksTestStackName]
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
  let arguments = ["stack", "select", awsEksTestStackName] ++ ["--create" | createIfMissing]
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
                    | isMissingPulumiStackError awsEksTestStackName (renderProcessDetail output) ->
                        PulumiStackMissing
                    | otherwise ->
                        PulumiStackSelectFailed (renderProcessDetail output)

pulumiUp :: FilePath -> [(String, String)] -> IO ExitCode
pulumiUp projectDir environment =
  runPulumiCommand projectDir environment ["up", "--yes", "--stack", awsEksTestStackName]

pulumiDestroyQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiDestroyQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["destroy", "--yes", "--stack", awsEksTestStackName]

pulumiRefreshQuiet :: FilePath -> [(String, String)] -> IO (Either String ())
pulumiRefreshQuiet projectDir environment =
  runPulumiCommandQuiet projectDir environment ["refresh", "--yes", "--stack", awsEksTestStackName]

pulumiStackRemoveQuiet :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiStackRemoveQuiet projectDir environment force =
  runPulumiCommandQuiet
    projectDir
    environment
    (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsEksTestStackName])

pulumiLoginEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiLoginEither projectDir environment summary
  | summary = pulumiLoginQuiet projectDir environment
  | otherwise = exitToEither "pulumi login" <$> pulumiLogin projectDir environment

pulumiDestroyEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiDestroyEither projectDir environment summary
  | summary = pulumiDestroyQuiet projectDir environment
  | otherwise =
      exitToEither "pulumi destroy"
        <$> runPulumiCommand projectDir environment ["destroy", "--yes", "--stack", awsEksTestStackName]

pulumiRefreshEither :: FilePath -> [(String, String)] -> Bool -> IO (Either String ())
pulumiRefreshEither projectDir environment summary
  | summary = pulumiRefreshQuiet projectDir environment
  | otherwise =
      exitToEither "pulumi refresh"
        <$> runPulumiCommand projectDir environment ["refresh", "--yes", "--stack", awsEksTestStackName]

pulumiStackRemoveEither :: FilePath -> [(String, String)] -> Bool -> Bool -> IO (Either String ())
pulumiStackRemoveEither projectDir environment force summary
  | summary = pulumiStackRemoveQuiet projectDir environment force
  | otherwise =
      exitToEither "pulumi stack rm"
        <$> runPulumiCommand
          projectDir
          environment
          (["stack", "rm", "--yes", "--remove-backups"] ++ ["--force" | force] ++ [awsEksTestStackName])

exitToEither :: String -> ExitCode -> Either String ()
exitToEither _ ExitSuccess = Right ()
exitToEither label (ExitFailure code) = Left (label ++ " exited with code " ++ show code)

pulumiStackOutputs :: FilePath -> [(String, String)] -> IO (Either String Value)
pulumiStackOutputs projectDir environment = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "pulumi"
        , subprocessArguments = ["stack", "output", "--json", "--stack", awsEksTestStackName]
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

-- | Sprint 4.18 fifth chunk: materialize the EKS kubeconfig into a scoped
-- temp file (via @aws eks update-kubeconfig --kubeconfig \<tempfile\>@),
-- hand the path to the action, then clean up on exit. Replaces the
-- legacy cross-invocation persistent file at
-- @.prodbox-state\/aws-eks-test\/kubeconfig@.
--
-- Internally re-derives the cluster name from the live MinIO backend
-- snapshot and the region from settings. Throws via 'error' when:
--
--   * 'validateAndLoadSettings' fails;
--   * @aws.region@ is empty;
--   * the live backend has no @aws-eks-test@ snapshot to read; or
--   * @aws eks update-kubeconfig@ fails / exits non-zero.
--
-- The bracket guarantees the temp file is removed on all exit paths
-- including async exceptions in the action.
withEksKubeconfig :: FilePath -> (FilePath -> IO a) -> IO a
withEksKubeconfig repoRoot action = do
  settingsResult <- validateAndLoadSettings repoRoot
  settings <- case settingsResult of
    Left err -> error ("withEksKubeconfig: settings load failed: " ++ err)
    Right s -> pure s
  let regionText = Text.unpack (Text.strip (region (aws (validatedConfig settings))))
  when (null regionText) $
    error
      "withEksKubeconfig: aws.region must be set in prodbox-config.dhall before materializing the AWS EKS kubeconfig"
  snapshotMaybe <- fetchAwsEksTestSnapshotFromBackend repoRoot
  snapshot <- case snapshotMaybe of
    Nothing ->
      error
        "withEksKubeconfig: aws-eks-test stack snapshot unavailable from the live MinIO Pulumi backend; cannot materialize EKS kubeconfig"
    Just s -> pure s
  let clusterName = eksSnapshotClusterName snapshot
  systemTemp <- getTemporaryDirectory
  bracket
    (openTempFile systemTemp "prodbox-eks-kubeconfig-")
    ( \(path, handle) -> do
        hClose handle `catch` \(_ :: IOException) -> pure ()
        removeFile path `catch` \(_ :: IOException) -> pure ()
    )
    ( \(tempPath, handle) -> do
        -- aws eks update-kubeconfig writes the YAML body itself; close
        -- the empty Haskell-side handle so the AWS CLI can overwrite.
        hClose handle
        outputResult <-
          runAwsCommandWithSettings
            repoRoot
            [ "eks"
            , "update-kubeconfig"
            , "--region"
            , regionText
            , "--name"
            , clusterName
            , "--kubeconfig"
            , tempPath
            ]
        case outputResult of
          Left err ->
            error ("withEksKubeconfig: aws eks update-kubeconfig failed to start: " ++ err)
          Right output ->
            case processExitCode output of
              ExitFailure _ ->
                let detail = trim (processStderr output) ++ " " ++ trim (processStdout output)
                 in error
                      ( "withEksKubeconfig: aws eks update-kubeconfig failed for cluster `"
                          ++ clusterName
                          ++ "`: "
                          ++ detail
                      )
              ExitSuccess -> action tempPath
    )

runAwsCommandWithSettings :: FilePath -> [String] -> IO (Either String ProcessOutput)
runAwsCommandWithSettings repoRoot arguments = do
  envResult <- settingsAwsEnv repoRoot
  case envResult of
    Left err -> pure (Left err)
    Right environment -> do
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments = arguments
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Nothing
            }
      pure $
        case result of
          Failure err -> Left err
          Success output -> Right output

runAwsJsonCommandMaybeMissing :: FilePath -> [String] -> IO (Either String (Maybe Value))
runAwsJsonCommandMaybeMissing repoRoot arguments = do
  outputResult <- runAwsCommandWithSettings repoRoot arguments
  pure $
    case outputResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess ->
            case eitherDecode (BL8.pack (processStdout output)) of
              Left err -> Left ("failed to parse AWS JSON response: " ++ err)
              Right value -> Right (Just value)
          ExitFailure _ ->
            let detail = trim (processStderr output) ++ " " ++ trim (processStdout output)
             in if isResourceMissing detail
                  then Right Nothing
                  else Left ("aws " ++ unwords arguments ++ " failed: " ++ detail)

runAwsTextCommandMaybeMissing :: FilePath -> [String] -> IO (Either String (Maybe String))
runAwsTextCommandMaybeMissing repoRoot arguments = do
  outputResult <- runAwsCommandWithSettings repoRoot arguments
  pure $
    case outputResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess ->
            let rendered = trim (processStdout output)
             in if null rendered || rendered == "None" || rendered == "null"
                  then Right Nothing
                  else Right (Just rendered)
          ExitFailure _ ->
            let detail = trim (processStderr output) ++ " " ++ trim (processStdout output)
             in if isResourceMissing detail
                  then Right Nothing
                  else Left ("aws " ++ unwords arguments ++ " failed: " ++ detail)

runAwsCommandAllowMissing :: FilePath -> [String] -> IO (Either String ())
runAwsCommandAllowMissing repoRoot arguments = do
  outputResult <- runAwsCommandWithSettings repoRoot arguments
  pure $
    case outputResult of
      Left err -> Left err
      Right output ->
        case processExitCode output of
          ExitSuccess -> Right ()
          ExitFailure _ ->
            let detail = trim (processStderr output) ++ " " ++ trim (processStdout output)
             in if isResourceMissing detail
                  then Right ()
                  else Left ("aws " ++ unwords arguments ++ " failed: " ++ detail)

purgeCanonicalAwsEksResidueIfPresent :: FilePath -> IO (Either String ())
purgeCanonicalAwsEksResidueIfPresent repoRoot = do
  residueResult <- discoverCanonicalAwsEksResidue repoRoot
  case residueResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right ())
    Right (Just residue) -> do
      nodeGroupDeleteResult <-
        runAwsCommandAllowMissing
          repoRoot
          [ "eks"
          , "delete-nodegroup"
          , "--cluster-name"
          , awsEksCanonicalClusterName
          , "--nodegroup-name"
          , awsEksCanonicalNodeGroupName
          ]
      case nodeGroupDeleteResult of
        Left err -> pure (Left err)
        Right () -> do
          nodeGroupWaitResult <-
            runAwsCommandAllowMissing
              repoRoot
              [ "eks"
              , "wait"
              , "nodegroup-deleted"
              , "--cluster-name"
              , awsEksCanonicalClusterName
              , "--nodegroup-name"
              , awsEksCanonicalNodeGroupName
              ]
          case nodeGroupWaitResult of
            Left err -> pure (Left err)
            Right () -> do
              clusterDeleteResult <-
                runAwsCommandAllowMissing
                  repoRoot
                  ["eks", "delete-cluster", "--name", awsEksCanonicalClusterName]
              case clusterDeleteResult of
                Left err -> pure (Left err)
                Right () -> do
                  clusterWaitResult <-
                    runAwsCommandAllowMissing
                      repoRoot
                      ["eks", "wait", "cluster-deleted", "--name", awsEksCanonicalClusterName]
                  case clusterWaitResult of
                    Left err -> pure (Left err)
                    Right () -> deleteVpcScopedResidue repoRoot residue

deleteVpcScopedResidue :: FilePath -> AwsEksCanonicalResidue -> IO (Either String ())
deleteVpcScopedResidue repoRoot residue = do
  deleteClusterSecurityGroupResult <-
    runAwsCommandAllowMissing
      repoRoot
      ["ec2", "delete-security-group", "--group-id", canonicalResidueClusterSecurityGroupId residue]
  case deleteClusterSecurityGroupResult of
    Left err -> pure (Left err)
    Right () -> do
      subnetDeleteResult <-
        foldM
          (deleteSubnetResidue repoRoot)
          (Right ())
          (canonicalResidueSubnetIds residue)
      case subnetDeleteResult of
        Left err -> pure (Left err)
        Right () -> do
          routeTableIdResult <-
            runAwsTextCommandMaybeMissing
              repoRoot
              [ "ec2"
              , "describe-route-tables"
              , "--filters"
              , "Name=tag:Name,Values=" ++ awsEksCanonicalPublicRouteTableTagName
              , "Name=vpc-id,Values=" ++ canonicalResidueVpcId residue
              , "--query"
              , "RouteTables[0].RouteTableId"
              , "--output"
              , "text"
              ]
          case routeTableIdResult of
            Left err -> pure (Left err)
            Right maybeRouteTableId -> do
              routeTableDeleteResult <-
                case maybeRouteTableId of
                  Nothing -> pure (Right ())
                  Just routeTableId ->
                    runAwsCommandAllowMissing repoRoot ["ec2", "delete-route-table", "--route-table-id", routeTableId]
              case routeTableDeleteResult of
                Left err -> pure (Left err)
                Right () -> do
                  igwIdResult <-
                    runAwsTextCommandMaybeMissing
                      repoRoot
                      [ "ec2"
                      , "describe-internet-gateways"
                      , "--filters"
                      , "Name=tag:Name,Values=" ++ awsEksCanonicalIgwTagName
                      , "Name=attachment.vpc-id,Values=" ++ canonicalResidueVpcId residue
                      , "--query"
                      , "InternetGateways[0].InternetGatewayId"
                      , "--output"
                      , "text"
                      ]
                  case igwIdResult of
                    Left err -> pure (Left err)
                    Right maybeIgwId -> do
                      igwDeleteResult <-
                        case maybeIgwId of
                          Nothing -> pure (Right ())
                          Just igwId -> do
                            detachResult <-
                              runAwsCommandAllowMissing
                                repoRoot
                                [ "ec2"
                                , "detach-internet-gateway"
                                , "--internet-gateway-id"
                                , igwId
                                , "--vpc-id"
                                , canonicalResidueVpcId residue
                                ]
                            case detachResult of
                              Left err -> pure (Left err)
                              Right () ->
                                runAwsCommandAllowMissing
                                  repoRoot
                                  ["ec2", "delete-internet-gateway", "--internet-gateway-id", igwId]
                      case igwDeleteResult of
                        Left err -> pure (Left err)
                        Right () -> do
                          vpcDeleteResult <-
                            runAwsCommandAllowMissing
                              repoRoot
                              ["ec2", "delete-vpc", "--vpc-id", canonicalResidueVpcId residue]
                          case vpcDeleteResult of
                            Left err -> pure (Left err)
                            Right () -> deleteIamRoleResidue repoRoot residue

deleteSubnetResidue :: FilePath -> Either String () -> String -> IO (Either String ())
deleteSubnetResidue repoRoot acc subnetId =
  case acc of
    Left err -> pure (Left err)
    Right () ->
      runAwsCommandAllowMissing repoRoot ["ec2", "delete-subnet", "--subnet-id", subnetId]

deleteIamRoleResidue :: FilePath -> AwsEksCanonicalResidue -> IO (Either String ())
deleteIamRoleResidue repoRoot residue = do
  clusterRoleDeleteResult <-
    deleteRoleWithPolicies
      repoRoot
      (canonicalResidueClusterRoleName residue)
      ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
  case clusterRoleDeleteResult of
    Left err -> pure (Left err)
    Right () ->
      case canonicalResidueNodeRoleName residue of
        Nothing -> pure (Right ())
        Just nodeRoleName ->
          deleteRoleWithPolicies
            repoRoot
            nodeRoleName
            [ "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
            , "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
            , "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
            ]

deleteRoleWithPolicies :: FilePath -> String -> [String] -> IO (Either String ())
deleteRoleWithPolicies repoRoot roleName policyArns = do
  detachResult <-
    foldM
      (detachRolePolicy repoRoot roleName)
      (Right ())
      policyArns
  case detachResult of
    Left err -> pure (Left err)
    Right () -> runAwsCommandAllowMissing repoRoot ["iam", "delete-role", "--role-name", roleName]

detachRolePolicy :: FilePath -> String -> Either String () -> String -> IO (Either String ())
detachRolePolicy repoRoot roleName acc policyArn =
  case acc of
    Left err -> pure (Left err)
    Right () ->
      runAwsCommandAllowMissing
        repoRoot
        [ "iam"
        , "detach-role-policy"
        , "--role-name"
        , roleName
        , "--policy-arn"
        , policyArn
        ]

resourceStillExists :: FilePath -> [String] -> IO (Either String Bool)
resourceStillExists _ [] = pure (Left "resource existence check requires a command")
resourceStillExists repoRoot (subprocessPath : subprocessArguments) = do
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
                    else pure (Left (unwords (subprocessPath : subprocessArguments) ++ " failed: " ++ detail))

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
        , "nosuchentity"
        ]

isSubstring :: String -> String -> Bool
isSubstring needle haystack = any (startsWith needle) (allTails haystack)
 where
  startsWith [] _ = True
  startsWith _ [] = False
  startsWith (a : as) (b : bs) = a == b && startsWith as bs

allTails :: [a] -> [[a]]
allTails [] = [[]]
allTails s@(_ : rest) = s : allTails rest

toLowerAscii :: Char -> Char
toLowerAscii c
  | isAsciiUpper c = toEnum (fromEnum c + 32)
  | otherwise = c

assertNoAwsEksTestStackResidue :: FilePath -> Maybe AwsEksTestStackSnapshot -> IO (Either String ())
assertNoAwsEksTestStackResidue repoRoot maybeSnapshot = do
  snapshot <- case maybeSnapshot of
    Just s -> pure (Just s)
    Nothing -> fetchAwsEksTestSnapshotFromBackend repoRoot
  case snapshot of
    Nothing -> do
      discoveredResidueResult <- discoverCanonicalAwsEksResidue repoRoot
      pure $
        case discoveredResidueResult of
          Left err -> Left err
          Right Nothing -> Right ()
          Right (Just _) ->
            Left ("AWS EKS test stack residue remains: cluster=" ++ awsEksCanonicalClusterName)
    Just current -> do
      remaining <- checkResidueItems repoRoot current
      case remaining of
        Left err -> pure (Left err)
        Right items ->
          if null items
            then pure (Right ())
            else pure (Left ("AWS EKS test stack residue remains: " ++ joinComma items))

checkResidueItems :: FilePath -> AwsEksTestStackSnapshot -> IO (Either String [String])
checkResidueItems repoRoot snapshot = do
  clusterResult <-
    resourceStillExists
      repoRoot
      ["aws", "eks", "describe-cluster", "--name", eksSnapshotClusterName snapshot]
  nodeGroupResult <-
    resourceStillExists
      repoRoot
      [ "aws"
      , "eks"
      , "describe-nodegroup"
      , "--cluster-name"
      , eksSnapshotClusterName snapshot
      , "--nodegroup-name"
      , eksSnapshotNodeGroupName snapshot
      ]
  clusterRoleResult <-
    resourceStillExists
      repoRoot
      ["aws", "iam", "get-role", "--role-name", eksSnapshotClusterRoleName snapshot]
  nodeRoleResult <-
    resourceStillExists
      repoRoot
      ["aws", "iam", "get-role", "--role-name", eksSnapshotNodeRoleName snapshot]
  vpcResult <-
    resourceStillExists repoRoot ["aws", "ec2", "describe-vpcs", "--vpc-ids", eksSnapshotVpcId snapshot]
  subnetResults <- forM (eksSnapshotSubnetIds snapshot) $ \subnetId ->
    resourceStillExists repoRoot ["aws", "ec2", "describe-subnets", "--subnet-ids", subnetId]
  sgResult <-
    resourceStillExists
      repoRoot
      [ "aws"
      , "ec2"
      , "describe-security-groups"
      , "--group-ids"
      , eksSnapshotClusterSecurityGroupId snapshot
      ]
  let allResults =
        [ ("cluster=" ++ eksSnapshotClusterName snapshot, clusterResult)
        , ("node-group=" ++ eksSnapshotNodeGroupName snapshot, nodeGroupResult)
        , ("cluster-role=" ++ eksSnapshotClusterRoleName snapshot, clusterRoleResult)
        , ("node-role=" ++ eksSnapshotNodeRoleName snapshot, nodeRoleResult)
        , ("vpc=" ++ eksSnapshotVpcId snapshot, vpcResult)
        ]
          ++ zipWith (\sid r -> ("subnet=" ++ sid, r)) (eksSnapshotSubnetIds snapshot) subnetResults
          ++ [("security-group=" ++ eksSnapshotClusterSecurityGroupId snapshot, sgResult)]
  case mapM snd allResults of
    Left err -> pure (Left err)
    Right existsList ->
      pure (Right [label | (label, True) <- zip (map fst allResults) existsList])

ensureAwsEksTestStackResources :: FilePath -> IO ExitCode
ensureAwsEksTestStackResources repoRoot = do
  snapshot <- fetchAwsEksTestSnapshotFromBackend repoRoot
  case snapshot of
    Nothing -> do
      purgeResult <- purgeCanonicalAwsEksResidueIfPresent repoRoot
      case purgeResult of
        Left err -> failWith err
        Right () -> continueEnsure
    Just _ -> continueEnsure
 where
  continueEnsure = do
    let projectDir = awsEksTestPulumiProjectDir repoRoot
    projectExists <- doesFileExist (projectDir </> "Pulumi.yaml")
    if not projectExists
      then failWith ("Pulumi AWS EKS test project missing: " ++ projectDir)
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
                  configResult <- resolveAwsEksTestStackConfig
                  case configResult of
                    Left err -> pure (Left err)
                    Right stackConfig -> do
                      baseEnvironmentResult <- pulumiEksBaseEnv repoRoot localPort accessKey secretKey
                      case baseEnvironmentResult of
                        Left err -> pure (Left err)
                        Right baseEnvironment -> do
                          loginExit <- pulumiLogin projectDir baseEnvironment
                          case loginExit of
                            ExitFailure _ -> pure (Left "pulumi login failed")
                            ExitSuccess -> do
                              selectExit <- pulumiStackSelect projectDir baseEnvironment True
                              case selectExit of
                                PulumiStackSelected -> do
                                  syncExit <- syncAwsEksTestStackConfig projectDir baseEnvironment stackConfig
                                  case syncExit of
                                    ExitFailure _ -> pure (Left "pulumi config set failed")
                                    ExitSuccess -> do
                                      upExit <- pulumiUp projectDir baseEnvironment
                                      case upExit of
                                        ExitFailure _ -> pure (Left "pulumi up failed")
                                        ExitSuccess -> do
                                          outputsResult <- pulumiStackOutputs projectDir baseEnvironment
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
                                                      writeOutput (renderAwsEksTestStackReport snapshot objectCount)
                                                      pure (Right ())
                                PulumiStackMissing ->
                                  pure (Left "pulumi stack select reported a missing stack after --create")
                                PulumiStackSelectFailed detail ->
                                  pure (Left ("pulumi stack select failed: " ++ detail))
        case portForwardResult of
          Left err -> failWith err
          Right (Left err) -> failWith err
          Right (Right ()) -> pure ExitSuccess

destroyAwsEksTestStack :: FilePath -> Bool -> IO ExitCode
destroyAwsEksTestStack repoRoot summary = do
  statusResult <- destroyAwsEksTestStackStatus repoRoot summary
  case statusResult of
    Left err -> failWith err
    Right status -> do
      writeOutputLine ("AWS EKS test stack: " ++ status)
      pure ExitSuccess

destroyAwsEksTestStackStatus :: FilePath -> Bool -> IO (Either String String)
destroyAwsEksTestStackStatus repoRoot summary = do
  currentSnapshot <- fetchAwsEksTestSnapshotFromBackend repoRoot
  let projectDir = awsEksTestPulumiProjectDir repoRoot
  portForwardResult <- withMinioPortForward $ \localPort -> do
    credsResult <- readMinioCredentials
    case credsResult of
      Left err -> pure (Left err)
      Right (accessKey, secretKey) -> do
        bucketResult <- ensureMinioBackendBucket localPort accessKey secretKey
        case bucketResult of
          Left err -> pure (Left err)
          Right () -> do
            backendEnvironment <- pulumiBackendBaseEnv localPort accessKey secretKey
            loginResult <- pulumiLoginEither projectDir backendEnvironment summary
            case loginResult of
              Left err -> pure (Left ("pulumi login failed: " ++ err))
              Right () -> do
                selectExit <- pulumiStackSelect projectDir backendEnvironment False
                case selectExit of
                  PulumiStackSelected -> do
                    operationalCredentialsResult <- loadOperationalAwsCredentials repoRoot
                    case operationalCredentialsResult of
                      Left err ->
                        pure
                          ( Left
                              ( "operational AWS credentials are required to destroy the AWS EKS test stack once a Pulumi stack exists: "
                                  ++ err
                              )
                          )
                      Right operationalCredentials -> do
                        configResult <- resolveAwsEksTestStackConfig
                        case configResult of
                          Left err -> pure (Left err)
                          Right stackConfig -> do
                            let providerEnvironment =
                                  backendEnvironment ++ pulumiAwsProviderEnv operationalCredentials
                            syncExit <- syncAwsEksTestStackConfig projectDir providerEnvironment stackConfig
                            case syncExit of
                              ExitFailure _ -> pure (Left "pulumi config set failed")
                              ExitSuccess -> do
                                -- Sprint 4.23: drain the EKS cluster's
                                -- AWS-affecting K8s resources (LoadBalancer
                                -- Services, ALB Ingresses, Delete-reclaim
                                -- PVCs) before the Pulumi destroy so the AWS
                                -- Load Balancer Controller + EBS CSI driver
                                -- release their ELB / CNI / EBS ENIs while
                                -- still alive. This gives AWS time to free the
                                -- subnet's ENIs so `pulumi destroy` doesn't hit
                                -- DependencyViolation on subnet deletion (the
                                -- May 28/29 incidents). Best-effort + safe when
                                -- the cluster is unreachable: a missing /
                                -- unreachable cluster logs a diagnostic and
                                -- proceeds to the destroy (the destroy is the
                                -- goal). Extends Sprint 4.17.b's cascade drain
                                -- to the per-run eks-destroy path, which both
                                -- the harness postflight
                                -- (`prodbox pulumi eks-destroy --yes`) and the
                                -- cascade (`reconcileAbsent` -> PulumiEksDestroy)
                                -- route through.
                                drainAwsEksClusterBeforeDestroy
                                  repoRoot
                                  operationalCredentials
                                destroyResult <- pulumiDestroyEither projectDir providerEnvironment summary
                                case destroyResult of
                                  Left _ -> do
                                    _ <- pulumiRefreshEither projectDir providerEnvironment summary
                                    retryResult <- pulumiDestroyEither projectDir providerEnvironment summary
                                    case retryResult of
                                      Left err -> pure (Left ("pulumi destroy failed after refresh: " ++ err))
                                      Right () -> completeDestroy repoRoot projectDir providerEnvironment currentSnapshot summary
                                  Right () ->
                                    completeDestroy repoRoot projectDir providerEnvironment currentSnapshot summary
                  PulumiStackMissing -> do
                    case currentSnapshot of
                      Nothing ->
                        pure (Right "already absent from the local Pulumi backend")
                      Just _ -> finalizeDestroy repoRoot currentSnapshot
                  PulumiStackSelectFailed detail ->
                    pure (Left ("pulumi stack select failed: " ++ detail))
  case portForwardResult of
    Left err ->
      case currentSnapshot of
        Nothing ->
          pure (Right "no local Pulumi backend or saved residue snapshot; nothing to destroy")
        Just _ ->
          pure
            (Left ("local MinIO backend unavailable while an AWS EKS test stack snapshot still exists: " ++ err))
    Right (Left err) -> pure (Left err)
    Right (Right status) -> pure (Right status)

completeDestroy
  :: FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe AwsEksTestStackSnapshot
  -> Bool
  -> IO (Either String String)
completeDestroy repoRoot projectDir environment currentSnapshot summary = do
  _ <- pulumiStackRemoveEither projectDir environment False summary
  finalizeDestroy repoRoot currentSnapshot

-- | Sprint 4.23: best-effort K8s drain of the per-run @aws-eks-test@
-- cluster's AWS-affecting resources, run immediately before the
-- @pulumi destroy@ so the AWS Load Balancer Controller and EBS CSI
-- driver release their ELB / CNI / EBS ENIs while their controllers are
-- still alive. Mirrors the Sprint 4.17.b cascade drain
-- ('Prodbox.CLI.Rke2.runCascadeDrainPhase') but targets the per-run EKS
-- cluster directly via its own kubeconfig instead of the host
-- substrate's cluster, and is wired into the eks-destroy path so it
-- covers BOTH the harness postflight
-- (@prodbox pulumi eks-destroy --yes@) and the cascade
-- (@reconcileAbsent@ -> @PulumiEksDestroy@).
--
-- The drain is **best-effort and safe when the cluster is
-- unreachable**: if the EKS kubeconfig file is absent (e.g. the stack is
-- already partially gone, or this is a fresh process that never
-- materialized it) the drain is skipped with a diagnostic and the
-- destroy proceeds. 'K8sDrain.drainAwsAffectingK8sResources' itself
-- probes reachability first, so an unreachable-but-present kubeconfig
-- yields 'K8sDrain.DrainSkipped'. A drain failure / timeout NEVER
-- hard-fails the destroy — the destroy is the goal; the worst case is
-- the pre-Sprint-4.23 behavior where the destroy races AWS's async ENI
-- cleanup and may hit @DependencyViolation@ (which Sprint 7.10 then
-- preserves operational creds for, so the orphans can be destroyed on
-- retry).
--
-- Limitation: the kubeconfig is materialized during
-- 'ensureAwsEksTestStackResources' (Sprint 4.18) and persists on disk at
-- 'awsEksTestKubeconfigPath'. Within a single @prodbox test all@ run
-- (bootstrap -> validations -> postflight destroy) it is present, so the
-- harness postflight path drains. A standalone
-- @prodbox pulumi eks-destroy --yes@ invocation in a process that never
-- ran the ensure step will find no kubeconfig and skip the drain (then
-- destroy) rather than re-materialize it from the backend snapshot —
-- the smallest safe version that does not add a backend round-trip just
-- to drain.
drainAwsEksClusterBeforeDestroy :: FilePath -> Credentials -> IO ()
drainAwsEksClusterBeforeDestroy repoRoot operationalCredentials = do
  -- Sprint 4.18 fifth chunk: re-derive the kubeconfig into a scoped temp
  -- file via 'withEksKubeconfig'. A bracket-setup failure (snapshot
  -- unreachable, aws eks update-kubeconfig fails) is converted via 'try'
  -- to a skip-with-diagnostic, preserving the pre-migration best-effort
  -- semantic where a missing kubeconfig means "the cluster may already
  -- be gone" and the destroy proceeds anyway.
  drainAttempt <-
    try
      ( withEksKubeconfig repoRoot $ \kubeconfigPath -> do
          writeOutputLine
            ( "Per-run EKS drain (cluster="
                ++ awsEksCanonicalClusterName
                ++ "): deleting LoadBalancer Services, ALB Ingresses, and "
                ++ "Delete-reclaim PVCs before `pulumi destroy` so AWS releases "
                ++ "the ELB / CNI ENIs (DependencyViolation guard)."
            )
          parentEnv <- getEnvironment
          let drainEnvVars = buildAwsEksDrainEnv kubeconfigPath operationalCredentials parentEnv
              drainEnv =
                K8sDrain.K8sDrainEnv
                  { K8sDrain.drainEnvironment = drainEnvVars
                  , K8sDrain.drainWorkingDirectory = Just repoRoot
                  }
          drainResult <- K8sDrain.drainAwsAffectingK8sResources drainEnv K8sDrain.defaultDrainTimeout
          case drainResult of
            K8sDrain.DrainSucceeded ->
              writeOutputLine
                "Per-run EKS drain complete; proceeding to `pulumi destroy`."
            K8sDrain.DrainSkipped reason ->
              writeDiagnosticLine
                ( "Per-run EKS drain skipped: "
                    ++ reason
                    ++ " Proceeding to `pulumi destroy` (best-effort)."
                )
            K8sDrain.DrainTimedOut survivors ->
              writeDiagnosticLine
                ( "Per-run EKS drain timed out before `pulumi destroy` "
                    ++ "(survivors: "
                    ++ joinComma survivors
                    ++ "); proceeding to destroy anyway. AWS may not have "
                    ++ "released every ENI yet, so the destroy could still hit "
                    ++ "DependencyViolation."
                )
            K8sDrain.DrainFailed err ->
              writeDiagnosticLine
                ( "Per-run EKS drain failed before `pulumi destroy`: "
                    ++ err
                    ++ "; proceeding to destroy anyway (the destroy is the goal)."
                )
      ) ::
      IO (Either SomeException ())
  case drainAttempt of
    Left exc ->
      writeDiagnosticLine
        ( "Per-run EKS drain skipped: kubeconfig materialization failed ("
            ++ show exc
            ++ "); the EKS cluster may already be gone, or the live MinIO "
            ++ "backend is unreachable. Proceeding directly to `pulumi destroy`."
        )
    Right () -> pure ()

-- | Sprint 4.23 helper: build the @KUBECONFIG@ + @AWS_*@ environment for
-- the per-run EKS drain's kubectl subprocesses. Mirrors
-- 'Prodbox.CLI.Rke2.buildDrainEnvironment' for @SubstrateAws@ but takes
-- already-resolved 'Credentials' (operational, with the
-- admin-simulation fallback from 'loadOperationalAwsCredentials') so the
-- drain reuses the same credential the destroy will use. @KUBECONFIG@
-- and the @AWS_*@ overrides are prepended so they take precedence over
-- any inherited values when @aws eks get-token@ authenticates.
buildAwsEksDrainEnv
  :: FilePath -> Credentials -> [(String, String)] -> [(String, String)]
buildAwsEksDrainEnv kubeconfigPath creds parentEnv =
  baseOverrides ++ tokenOverrides ++ parentEnv
 where
  baseOverrides =
    [ ("KUBECONFIG", kubeconfigPath)
    , ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id creds))
    , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key creds))
    , ("AWS_DEFAULT_REGION", Text.unpack (region creds))
    , ("AWS_REGION", Text.unpack (region creds))
    ]
  tokenOverrides = case session_token creds of
    Nothing -> []
    Just tok -> [("AWS_SESSION_TOKEN", Text.unpack tok)]

finalizeDestroy :: FilePath -> Maybe AwsEksTestStackSnapshot -> IO (Either String String)
finalizeDestroy repoRoot currentSnapshot = do
  purgeResult <- purgeCanonicalAwsEksResidueIfPresent repoRoot
  case purgeResult of
    Left err -> pure (Left err)
    Right () -> do
      residueResult <- assertNoAwsEksTestStackResidue repoRoot currentSnapshot
      case residueResult of
        Left err -> pure (Left err)
        Right () -> pure (Right "destroyed and residue check passed")

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
