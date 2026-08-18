{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The @aws-test@ public surface after the Provider-Worker cutover.  The
-- host retains only pure output decoding and read-only checkpoint consumers;
-- every create/destroy effect is a typed Authority-dispatched Provider intent.
module Prodbox.Infra.AwsTestStack
  ( AwsTestNode (..)
  , AwsTestStackSnapshot (..)
  , awsTestStackName
  , ensureAwsTestStackResources
  , ensureAwsTestStackResourcesWithAuthentication
  , destroyAwsTestStack
  , destroyAwsTestStackWithAuthentication
  , awsTestStackResidueStatus
  , assertNoAwsTestStackResidue
  , renderAwsTestStackReport
  , withAwsTestSshPrivateKey
  , parseAwsTestNodesFromOutputs
  , parseAwsTestStackFromOutputs
  )
where

import Control.Exception (IOException, bracket, catch)
import Control.Monad (when)
import Data.Aeson (Value (Array, Object, String), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.CLI.Output (writeError, writeOutputLine)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthentication
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchAuthenticatedProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( RegisteredStackCreationSubmission (submittedCreateEvidence)
  , renderRegisteredStackCreationSubmitError
  , submitRegisteredStackCreation
  )
import Prodbox.Error (fatalError)
import Prodbox.Http.Client (defaultHttpConfig, httpGetText, renderHttpError)
import Prodbox.Infra.StackOutputs qualified as StackOutputs
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (DestroyRegisteredStack, ReconcileRegisteredStack)
  , ProviderRevision
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (hClose, hPutStr, openTempFile)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)

awsTestStackName :: String
awsTestStackName = "aws-test"

awsTestStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsTestStackResidueStatus repoRoot =
  -- Sprint 4.81: this registry adapter answers a status-shaped question, so it
  -- projects the observation's status. The layer is not discarded silently --
  -- the cascade path consumes the observation itself.
  ResidueStatus.residueObservationStatus . LiveResidue.perRunAwsTest
    <$> LiveResidue.queryPerRunResidueStatuses repoRoot

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

ensureAwsTestStackResources :: FilePath -> IO ExitCode
ensureAwsTestStackResources repoRoot =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    ensureAwsTestStackResourcesWithAuthentication authentication repoRoot

ensureAwsTestStackResourcesWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ExitCode
ensureAwsTestStackResourcesWithAuthentication authentication repoRoot = do
  publicIp <- fetchPublicIpv4
  case ( mkProviderStackRef "aws-test"
       , mkProviderRevision 1
       , case publicIp of
           Left err -> Left err
           Right value ->
             case mkAwsTestProviderStackConfig (Text.pack (value <> "/32")) of
               Left err -> Left (show err)
               Right config -> Right config
       ) of
    (Right ref, Right revision, Right config) ->
      -- Sprint 4.84: creation commits this cycle's run-invariant lifecycle
      -- generation, so a later cleanup run can name the stack it created.
      submitStackCreation
        authentication
        repoRoot
        "operator-reconcile-aws-test"
        "AWS test Provider receipt: "
        revision
        (ReconcileRegisteredStack ref revision config)
    (refResult, revisionResult, configResult) ->
      failWith
        ( "build typed AWS test Provider intent: "
            ++ show (refResult, revisionResult, configResult)
        )

destroyAwsTestStack :: FilePath -> Bool -> IO ExitCode
destroyAwsTestStack repoRoot quietOutput =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    destroyAwsTestStackWithAuthentication authentication repoRoot quietOutput

destroyAwsTestStackWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Bool
  -> IO ExitCode
destroyAwsTestStackWithAuthentication authentication _repoRoot _quietOutput =
  case ( mkProviderStackRef "aws-test"
       , mkProviderRevision 1
       , mkAwsTestProviderStackConfig "127.0.0.1/32"
       ) of
    (Right ref, Right revision, Right config) ->
      dispatchStack
        authentication
        "operator-destroy-aws-test"
        "AWS test Provider destroy receipt: "
        (DestroyRegisteredStack ref revision config)
    (refResult, revisionResult, configResult) ->
      failWith
        ( "build typed AWS test destroy intent: "
            ++ show (refResult, revisionResult, configResult)
        )

-- | Sprint 4.84: create a registered stack and commit its lifecycle generation
-- in one admitted lane.
submitStackCreation
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Text.Text
  -> String
  -> ProviderRevision
  -> ProviderIntent
  -> IO ExitCode
submitStackCreation authentication repoRoot prefix label revision intent = do
  submitted <-
    submitRegisteredStackCreation authentication repoRoot prefix revision intent
  case submitted of
    Left err -> failWith (renderRegisteredStackCreationSubmitError err)
    Right submission -> do
      writeOutputLine
        (label ++ Text.unpack (submittedCreateEvidence submission))
      pure ExitSuccess

dispatchStack
  :: LifecycleAuthorityAuthentication
  -> Text.Text
  -> String
  -> ProviderIntent
  -> IO ExitCode
dispatchStack authentication submissionPrefix label intent = do
  result <-
    dispatchAuthenticatedProviderIntentFresh authentication submissionPrefix intent
  case result of
    Left err -> failWith (renderProviderCallerError err)
    Right evidence -> do
      writeOutputLine (label ++ Text.unpack evidence)
      pure ExitSuccess

withOperatorLifecycleAuthority
  :: FilePath
  -> (LifecycleAuthorityAuthentication -> IO ExitCode)
  -> IO ExitCode
withOperatorLifecycleAuthority repoRoot action = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication LifecycleAuthorityOperator repoRoot action
  case authenticated of
    Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
    Right exitCode -> pure exitCode

withAwsTestSshPrivateKey :: FilePath -> (FilePath -> IO value) -> IO value
withAwsTestSshPrivateKey repoRoot action = do
  outputsResult <-
    LiveResidue.fetchPerRunStackOutputs
      repoRoot
      (StackOutputs.StackName (Text.pack awsTestStackName))
  outputs <- either (error . ("aws-test checkpoint unavailable: " ++)) pure outputsResult
  privateKey <- case Map.lookup "ssh_private_key" outputs of
    Just value | not (Text.null value) -> pure (Text.unpack value)
    _ -> error "aws-test checkpoint is missing non-empty ssh_private_key"
  systemTemp <- getTemporaryDirectory
  bracket
    (openTempFile systemTemp "prodbox-aws-test-ssh-key-")
    ( \(path, handle) -> do
        hClose handle `catch` \(_ :: IOException) -> pure ()
        removeFile path `catch` \(_ :: IOException) -> pure ()
    )
    ( \(path, handle) -> do
        hPutStr handle privateKey
        when (last privateKey /= '\n') (hPutStr handle "\n")
        hClose handle
        setFileMode path (unionFileModes ownerReadMode ownerWriteMode)
        action path
    )

parseAwsTestNodesFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String [AwsTestNode]
parseAwsTestNodesFromOutputs outputs = do
  raw <- requireMapText outputs "nodes"
  case eitherDecode (BL8.pack (Text.unpack raw)) of
    Left err -> Left ("aws-test Pulumi output 'nodes' is not valid JSON: " ++ err)
    Right (Array values) -> traverse nodeFromJson (Vector.toList values)
    Right _ -> Left "aws-test Pulumi output 'nodes' must be a JSON array"

parseAwsTestStackFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String AwsTestStackSnapshot
parseAwsTestStackFromOutputs outputs = do
  backendBucket <- requireMapString outputs "backend_bucket"
  vpcId <- requireMapString outputs "vpc_id"
  subnetIds <- requireMapStringList outputs "subnet_ids"
  securityGroupId <- requireMapString outputs "security_group_id"
  nodes <- parseAwsTestNodesFromOutputs outputs
  pure
    AwsTestStackSnapshot
      { testSnapshotStackName = awsTestStackName
      , testSnapshotBackendBucket = backendBucket
      , testSnapshotVpcId = vpcId
      , testSnapshotSubnetIds = subnetIds
      , testSnapshotSecurityGroupId = securityGroupId
      , testSnapshotNodes = nodes
      }

nodeFromJson :: Value -> Either String AwsTestNode
nodeFromJson (Object value) =
  AwsTestNode
    <$> requireJsonString value "name"
    <*> requireJsonString value "availability_zone"
    <*> requireJsonString value "instance_id"
    <*> requireJsonString value "private_ip"
    <*> requireJsonString value "public_ip"
nodeFromJson _ = Left "aws-test node must be a JSON object"

requireJsonString :: KeyMap.KeyMap Value -> String -> Either String String
requireJsonString value field = case KeyMap.lookup (Key.fromString field) value of
  Just (String textValue) | not (Text.null textValue) -> Right (Text.unpack textValue)
  _ -> Left ("aws-test node is missing non-empty field '" ++ field ++ "'")

requireMapText
  :: Map.Map Text.Text Text.Text -> String -> Either String Text.Text
requireMapText outputs field = case Map.lookup (Text.pack field) outputs of
  Just value | not (Text.null value) -> Right value
  _ -> Left ("aws-test Pulumi outputs missing non-empty field '" ++ field ++ "'")

requireMapString
  :: Map.Map Text.Text Text.Text -> String -> Either String String
requireMapString outputs = fmap Text.unpack . requireMapText outputs

requireMapStringList
  :: Map.Map Text.Text Text.Text -> String -> Either String [String]
requireMapStringList outputs field = do
  raw <- requireMapText outputs field
  case eitherDecode (BL8.pack (Text.unpack raw)) of
    Left err -> Left ("aws-test Pulumi output '" ++ field ++ "' is not valid JSON: " ++ err)
    Right (Array values) -> traverse textEntry (Vector.toList values)
    Right _ -> Left ("aws-test Pulumi output '" ++ field ++ "' must be a JSON array")
 where
  textEntry (String value) | not (Text.null value) = Right (Text.unpack value)
  textEntry _ = Left ("aws-test Pulumi output '" ++ field ++ "' must contain non-empty strings")

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
        ++ concatMap renderNode (zip [0 :: Int ..] (testSnapshotNodes snapshot))
    )
 where
  renderNode (index, node) =
    [ "NODE_" ++ show index ++ "_NAME=" ++ testNodeName node
    , "NODE_" ++ show index ++ "_AZ=" ++ testNodeAvailabilityZone node
    , "NODE_" ++ show index ++ "_INSTANCE_ID=" ++ testNodeInstanceId node
    , "NODE_" ++ show index ++ "_PRIVATE_IP=" ++ testNodePrivateIp node
    , "NODE_" ++ show index ++ "_PUBLIC_IP=" ++ testNodePublicIp node
    ]

assertNoAwsTestStackResidue
  :: FilePath -> Maybe AwsTestStackSnapshot -> IO (Either String ())
assertNoAwsTestStackResidue repoRoot _ = do
  status <- awsTestStackResidueStatus repoRoot
  pure $ case status of
    ResidueStatus.ResidueAbsent -> Right ()
    ResidueStatus.ResiduePresent detail -> Left (ResidueStatus.renderResidueDetails detail)
    ResidueStatus.ResidueUnreachable detail ->
      Left (ResidueStatus.renderResidueUnreachableReason detail)

fetchPublicIpv4 :: IO (Either String String)
fetchPublicIpv4 = do
  result <- httpGetText defaultHttpConfig "https://api.ipify.org"
  pure $ case result of
    Left err -> Left ("failed to fetch public IP: " ++ renderHttpError err)
    Right body
      | length (filter (== '.') body) == 3 -> Right body
      | otherwise -> Left ("unexpected public IP response: " ++ body)

joinComma :: [String] -> String
joinComma = foldr join ""
 where
  join value "" = value
  join value rest = value ++ "," ++ rest

failWith :: String -> IO ExitCode
failWith detail = do
  writeError (fatalError (Text.pack detail))
  pure (ExitFailure 1)
