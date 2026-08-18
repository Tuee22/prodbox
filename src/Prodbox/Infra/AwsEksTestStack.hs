{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The @aws-eks@ surface after normal provider work moved behind the
-- Lifecycle Authority.  Host code may decode/read retained outputs and build
-- a scoped kubeconfig, but cannot execute Pulumi or mutate AWS resources.
module Prodbox.Infra.AwsEksTestStack
  ( AwsEksTestStackSnapshot (..)
  , awsEksTestStackName
  , awsEksCanonicalClusterName
  , ensureAwsEksTestStackResources
  , ensureAwsEksTestStackResourcesWithAuthentication
  , destroyAwsEksTestStack
  , destroyAwsEksTestStackWithAuthentication
  , awsEksTestStackResidueStatus
  , withEksKubeconfig
  , eksKubeconfig
  , assertNoAwsEksTestStackResidue
  , pulumiAwsProviderEnv
  , renderAwsEksTestStackReport
  , fetchAwsEksTestSnapshotFromBackend
  , fetchAwsEksTestSnapshotFromBackendWithAuthentication
  , parseAwsEksTestStackFromOutputs
  )
where

import Control.Concurrent.Async (withAsync)
import Control.Monad (forever)
import Data.Aeson (Value (Array, String), eitherDecode, encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.CLI.Output (writeError, writeOutputLine)
import Prodbox.ControlPlane.EksClientAuthClient (withEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  , eksClientAuthBearerToken
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  )
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
  , mkAwsEksProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry
import Prodbox.Settings
  ( Credentials (..)
  , requireOperationalAwsRegion
  , validateAndLoadSettings
  )
import Prodbox.Settings.Coordinate (awsRegionText)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createNamedPipe, ownerModes)

-- | Sprint 4.85: both names are projections of the typed lifecycle registry.
--
-- They were authored here, again in 'Prodbox.Lifecycle.LiveResidue', and a
-- third time inside the per-run EBS family's cluster ownership tag — four
-- statements of two facts, joined to nothing. The cluster name in particular is
-- load-bearing beyond narration: it is the tag the EBS reaper filters on and
-- the coordinate the controller-ownership relation is derived from, so a
-- rename that split these would have silently unaddressed a billable family.
awsEksTestStackName :: String
awsEksTestStackName = Text.unpack Registry.awsEksPulumiStackName

awsEksCanonicalClusterName :: String
awsEksCanonicalClusterName = Text.unpack Registry.awsEksProvisionedClusterName

awsEksTestStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsEksTestStackResidueStatus repoRoot =
  -- Sprint 4.81: this registry adapter answers a status-shaped question, so it
  -- projects the observation's status. The layer is not discarded silently --
  -- the cascade path consumes the observation itself.
  ResidueStatus.residueObservationStatus . LiveResidue.perRunAwsEksTest
    <$> LiveResidue.queryPerRunResidueStatuses repoRoot

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
  , eksSnapshotRetainedEbsAvailabilityZone :: String
  }
  deriving (Eq, Show)

ensureAwsEksTestStackResources :: FilePath -> IO ExitCode
ensureAwsEksTestStackResources repoRoot =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    ensureAwsEksTestStackResourcesWithAuthentication authentication repoRoot

ensureAwsEksTestStackResourcesWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ExitCode
ensureAwsEksTestStackResourcesWithAuthentication authentication repoRoot = do
  publicIp <- fetchPublicIpv4
  let configResult = case publicIp of
        Left err -> Left err
        Right value ->
          case mkAwsEksProviderStackConfig (Text.pack (value <> "/32")) of
            Left err -> Left (show err)
            Right config -> Right config
  case (mkProviderStackRef "aws-eks", mkProviderRevision 1, configResult) of
    (Right ref, Right revision, Right config) ->
      -- Sprint 4.84: creation goes through the submitting lane, which commits
      -- the run-invariant lifecycle generation for this cycle. Without it the
      -- stack exists and no later cleanup run can name the cycle it belongs to.
      submitStackCreation
        authentication
        repoRoot
        "operator-reconcile-aws-eks"
        "AWS EKS Provider receipt: "
        revision
        (ReconcileRegisteredStack ref revision config)
    (refResult, revisionResult, providerConfig) ->
      failWith
        ( "build typed AWS EKS Provider intent: "
            ++ show (refResult, revisionResult, providerConfig)
        )

destroyAwsEksTestStack :: FilePath -> Bool -> IO ExitCode
destroyAwsEksTestStack repoRoot quietOutput =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    destroyAwsEksTestStackWithAuthentication authentication repoRoot quietOutput

destroyAwsEksTestStackWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Bool
  -> IO ExitCode
destroyAwsEksTestStackWithAuthentication authentication _repoRoot _quietOutput =
  case ( mkProviderStackRef "aws-eks"
       , mkProviderRevision 1
       , mkAwsEksProviderStackConfig "127.0.0.1/32"
       ) of
    (Right ref, Right revision, Right config) ->
      dispatchStack
        authentication
        "operator-destroy-aws-eks"
        "AWS EKS Provider destroy receipt: "
        (DestroyRegisteredStack ref revision config)
    (refResult, revisionResult, configResult) ->
      failWith
        ( "build typed AWS EKS destroy intent: "
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
dispatchStack authentication prefix label intent = do
  result <- dispatchAuthenticatedProviderIntentFresh authentication prefix intent
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

fetchAwsEksTestSnapshotFromBackend :: FilePath -> IO (Maybe AwsEksTestStackSnapshot)
fetchAwsEksTestSnapshotFromBackend repoRoot = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> fetchAwsEksTestSnapshotFromBackendWithAuthentication authentication repoRoot)
  pure (either (const Nothing) id authenticated)

fetchAwsEksTestSnapshotFromBackendWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO (Maybe AwsEksTestStackSnapshot)
fetchAwsEksTestSnapshotFromBackendWithAuthentication authentication repoRoot = do
  outputs <-
    LiveResidue.fetchPerRunStackOutputsWithAuthentication
      authentication
      repoRoot
      (StackOutputs.StackName (Text.pack awsEksTestStackName))
  pure $ case outputs of
    Left _ -> Nothing
    Right value -> either (const Nothing) Just (parseAwsEksTestStackFromOutputs value)

parseAwsEksTestStackFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String AwsEksTestStackSnapshot
parseAwsEksTestStackFromOutputs outputs =
  AwsEksTestStackSnapshot awsEksTestStackName
    <$> requireOutputString outputs "backend_bucket"
    <*> requireOutputString outputs "cluster_name"
    <*> requireOutputString outputs "cluster_role_name"
    <*> requireOutputString outputs "node_group_name"
    <*> requireOutputString outputs "node_role_name"
    <*> requireOutputString outputs "vpc_id"
    <*> requireOutputStringList outputs "subnet_ids"
    <*> requireOutputString outputs "cluster_security_group_id"
    <*> requireOutputString outputs "cluster_oidc_issuer"
    <*> requireOutputString outputs "oidc_provider_arn"
    <*> requireOutputString outputs "aws_lb_controller_policy_arn"
    <*> requireOutputString outputs "aws_lb_controller_role_arn"
    <*> requireOutputString outputs "aws_lb_controller_role_name"
    <*> requireOutputString outputs "retained_ebs_availability_zone"

requireOutputString
  :: Map.Map Text.Text Text.Text -> Text.Text -> Either String String
requireOutputString outputs key = case Map.lookup key outputs of
  Just value | not (Text.null value) -> Right (Text.unpack value)
  _ -> Left ("aws-eks Pulumi outputs missing non-empty field '" ++ Text.unpack key ++ "'")

requireOutputStringList
  :: Map.Map Text.Text Text.Text -> Text.Text -> Either String [String]
requireOutputStringList outputs key = do
  raw <- requireOutputString outputs key
  case eitherDecode (BL8.pack raw) of
    Left err -> Left ("aws-eks Pulumi output '" ++ Text.unpack key ++ "' is invalid JSON: " ++ err)
    Right (Array values) -> traverse entry (Vector.toList values)
    Right _ -> Left ("aws-eks Pulumi output '" ++ Text.unpack key ++ "' must be an array")
 where
  entry (String value) | not (Text.null value) = Right (Text.unpack value)
  entry _ = Left ("aws-eks Pulumi output '" ++ Text.unpack key ++ "' must contain strings")

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
    , "RETAINED_EBS_AVAILABILITY_ZONE=" ++ eksSnapshotRetainedEbsAvailabilityZone snapshot
    ]

assertNoAwsEksTestStackResidue
  :: FilePath -> Maybe AwsEksTestStackSnapshot -> IO (Either String ())
assertNoAwsEksTestStackResidue repoRoot _ = do
  status <- awsEksTestStackResidueStatus repoRoot
  pure $ case status of
    ResidueStatus.ResidueAbsent -> Right ()
    ResidueStatus.ResiduePresent detail -> Left (ResidueStatus.renderResidueDetails detail)
    ResidueStatus.ResidueUnreachable detail ->
      Left (ResidueStatus.renderResidueUnreachableReason detail)

pulumiAwsProviderEnv :: Credentials -> [(String, String)]
pulumiAwsProviderEnv credentials =
  [ ("PRODBOX_PULUMI_AWS_ACCESS_KEY_ID", Text.unpack (access_key_id credentials))
  , ("PRODBOX_PULUMI_AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key credentials))
  , ("PRODBOX_PULUMI_AWS_REGION", Text.unpack (region credentials))
  , ("PRODBOX_PULUMI_AWS_DEFAULT_REGION", Text.unpack (region credentials))
  ]
    ++ maybe
      []
      (\token -> [("PRODBOX_PULUMI_AWS_SESSION_TOKEN", Text.unpack token)])
      (session_token credentials)

withEksKubeconfig :: FilePath -> (FilePath -> IO value) -> IO value
withEksKubeconfig repoRoot action = do
  settings <- validateAndLoadSettings repoRoot >>= either (error . ("load settings: " ++)) pure
  -- Sprint 1.89: the region is the parsed coordinate. The `null` test it
  -- replaces was an `error` call, so an unset region crashed here rather than
  -- refusing; `requireOperationalAwsRegion` still cannot be threaded into an
  -- error channel this function does not have, but the refusal now names the
  -- remedy and the value it admits cannot be malformed.
  awsRegion <-
    either
      (error . ("withEksKubeconfig: " ++))
      (pure . Text.unpack . awsRegionText)
      (requireOperationalAwsRegion settings)
  snapshot <-
    fetchAwsEksTestSnapshotFromBackend repoRoot
      >>= maybe (error "withEksKubeconfig: aws-eks checkpoint is unavailable") pure
  projected <-
    withEksClientAuthProjection
      LifecycleAuthorityOperator
      repoRoot
      (Text.pack awsRegion)
      (Text.pack (eksSnapshotClusterName snapshot))
      ( \projection ->
          withSystemTempDirectory "prodbox-eks-client-auth-" $ \directory -> do
            let kubeconfigPath = directory </> "kubeconfig.json"
                tokenFifoPath = directory </> "bearer-token"
            createNamedPipe tokenFifoPath ownerModes
            BL8.writeFile kubeconfigPath (encode (eksKubeconfig projection tokenFifoPath))
            withAsync
              ( forever
                  ( ByteString.writeFile
                      tokenFifoPath
                      (TextEncoding.encodeUtf8 (eksClientAuthBearerToken projection))
                  )
              )
              (const (action kubeconfigPath))
      )
  either (error . ("withEksKubeconfig: " ++) . show) pure projected

eksKubeconfig
  :: EksClientAuthProjection
  -> FilePath
  -> Value
eksKubeconfig projection tokenFifoPath =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Config" :: String)
    , "current-context" .= ("prodbox-eks" :: String)
    , "clusters"
        .= [ object
               [ "name" .= eksClientAuthClusterName projection
               , "cluster"
                   .= object
                     [ "server" .= eksClientAuthEndpoint projection
                     , "certificate-authority-data"
                         .= eksClientAuthCertificateAuthorityData projection
                     ]
               ]
           ]
    , "users"
        .= [ object
               [ "name" .= ("prodbox-provider" :: String)
               , "user" .= object ["tokenFile" .= tokenFifoPath]
               ]
           ]
    , "contexts"
        .= [ object
               [ "name" .= ("prodbox-eks" :: String)
               , "context"
                   .= object
                     [ "cluster" .= eksClientAuthClusterName projection
                     , "user" .= ("prodbox-provider" :: String)
                     ]
               ]
           ]
    ]

fetchPublicIpv4 :: IO (Either String String)
fetchPublicIpv4 = do
  result <- httpGetText defaultHttpConfig "https://api.ipify.org"
  pure $ case result of
    Left err -> Left ("failed to fetch public IP: " ++ renderHttpError err)
    Right body
      | length (filter (== '.') body) == 3 -> Right body
      | otherwise -> Left ("unexpected public IP response: " ++ body)

joinComma :: [String] -> String
joinComma = foldr (\value rest -> value ++ if null rest then "" else "," ++ rest) ""

failWith :: String -> IO ExitCode
failWith detail = do
  writeError (fatalError (Text.pack detail))
  pure (ExitFailure 1)
