{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The @aws-eks@ surface after normal provider work moved behind the
-- Lifecycle Authority.  Host code may decode/read retained outputs and build
-- a scoped kubeconfig, but cannot execute Pulumi or mutate AWS resources.
module Prodbox.Infra.AwsEksTestStack
  ( AwsEksTestStackSnapshot (..)
  , awsEksTestStackName
  , awsEksCanonicalClusterName
  , awsEksProviderReceiptLabel
  , awsEksDesiredNodeCount
  , loadAwsEksProviderConfig
  , ensureAwsEksTestStackResources
  , ensureAwsEksTestStackResourcesWithAuthentication
  , destroyAwsEksTestStack
  , destroyAwsEksTestStackWithAuthentication
  , awsEksTestStackResidueStatus
  , EksKubeconfigError (..)
  , renderEksKubeconfigError
  , withEksKubeconfig
  , withEksKubeconfigResult
  , bearerRefreshDelayMicroseconds
  , BearerRefresher (..)
  , withBearerRefreshUsing
  , bearerRefreshRetryMicroseconds
  , assertNoAwsEksTestStackResidue
  , pulumiAwsProviderEnv
  , renderAwsEksTestStackReport
  , fetchAwsEksTestSnapshotFromBackend
  , fetchAwsEksTestSnapshotFromBackendResult
  , fetchAwsEksTestSnapshotFromBackendWithAuthentication
  , parseAwsEksTestStackFromOutputs
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( Exception (displayException)
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , tryJust
  )
import Control.Monad (when)
import Data.Aeson (Value (Array, String), eitherDecode)
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine, writeError, writeOutputLine)
import Prodbox.Cluster.Topology (ClusterTopology, eksNodeGroupSize)
import Prodbox.ControlPlane.EksClientAuthClient (withEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection (eksClientAuthExpiresAtEpochSeconds)
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
import Prodbox.Infra.AwsFieldAudit (printFieldAfterCreate, withFieldDiff)
import Prodbox.Infra.StackOutputs qualified as StackOutputs
import Prodbox.Lifecycle.AwsAudit (AuditStack (AuditAwsEks))
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (DestroyRegisteredStack, ReconcileRegisteredStack)
  , ProviderRevision
  , ProviderRunMarker
  , ProviderStackConfig
  , mkAwsEksProfileProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( replaceEphemeralBearer
  , withEphemeralKubeconfigPath
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , ValidatedSettings (..)
  , requireAwsSubstrateProfile
  , requireOperationalAwsRegion
  , validateAndLoadSettings
  )
import Prodbox.Settings.AwsSubstrateProfile
  ( AwsSubstrateProfile
  , awsSubstrateEksMinimumNodeCount
  )
import Prodbox.Settings.Coordinate (awsRegionText)
import Prodbox.Supervision (withSupervisedChild)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

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

-- | What @aws stack eks reconcile@ prints before the Provider receipt. One
-- value, read by the producer and by the validation that asserts the output, so
-- the two cannot drift apart the way the superseded @STACK=@ report did.
awsEksProviderReceiptLabel :: String
awsEksProviderReceiptLabel = "AWS EKS Provider receipt: "

ensureAwsEksTestStackResources :: FilePath -> IO ExitCode
ensureAwsEksTestStackResources repoRoot =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    ensureAwsEksTestStackResourcesWithAuthentication authentication repoRoot

ensureAwsEksTestStackResourcesWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ExitCode
ensureAwsEksTestStackResourcesWithAuthentication authentication repoRoot = do
  configResult <- loadAwsEksProviderConfig repoRoot
  case (mkProviderStackRef "aws-eks", mkProviderRevision 1, configResult) of
    (Right ref, Right revision, Right config) -> do
      -- Sprint 4.84: creation goes through the submitting lane, which commits
      -- the run-invariant lifecycle generation for this cycle. Without it the
      -- stack exists and no later cleanup run can name the cycle it belongs to.
      created <-
        submitStackCreation
          authentication
          repoRoot
          "operator-reconcile-aws-eks"
          awsEksProviderReceiptLabel
          revision
          (ReconcileRegisteredStack ref revision config)
      -- Sprint 4.110: the field is printed and gates nothing, because after a
      -- create it legitimately holds the new stack.
      when (created == ExitSuccess) (printFieldAfterCreate authentication repoRoot AuditAwsEks)
      pure created
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
destroyAwsEksTestStackWithAuthentication authentication repoRoot _quietOutput = do
  configResult <- loadAwsEksProviderConfig repoRoot
  case (mkProviderStackRef "aws-eks", mkProviderRevision 1, configResult) of
    (Right ref, Right revision, Right config) ->
      -- Sprint 4.110: the destroy is bracketed by an inventory of the field it
      -- is meant to empty, and exits non-zero unless the closing one is clean.
      withFieldDiff authentication repoRoot AuditAwsEks $
        dispatchStack
          authentication
          "operator-destroy-aws-eks"
          "AWS EKS Provider destroy receipt: "
          (DestroyRegisteredStack ref revision config)
    (refResult, revisionResult, providerConfigResult) ->
      failWith
        ( "build typed AWS EKS destroy intent: "
            ++ show (refResult, revisionResult, providerConfigResult)
        )

loadAwsEksProviderConfig :: FilePath -> IO (Either String ProviderStackConfig)
loadAwsEksProviderConfig repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  pure $ do
    settings <- settingsResult
    authoredProfile <- requireAwsSubstrateProfile settings
    let desiredSize =
          awsEksDesiredNodeCount
            authoredProfile
            (cluster_topology (validatedConfig settings))
    case mkAwsEksProfileProviderStackConfig authoredProfile desiredSize of
      Left err -> Left (show err)
      Right config -> Right config

-- | The desired node count of the @aws-eks@ stack.
--
-- A deployment whose cluster is EKS authors the count in
-- @cluster_topology.Eks.node_group_size@, and that field stays the owner of the
-- shape. A deployment whose cluster is the home RKE2 one has no such field, and
-- the stack it provisions is a per-run test and recovery stack rather than the
-- cluster its workload runs on, so its count is the smallest the authored
-- profile admits. Refusing there would let the same stack be created under one
-- configuration and be undestroyable under another, and a destroy must not
-- depend on which cluster the operator's configuration describes.
awsEksDesiredNodeCount :: AwsSubstrateProfile -> ClusterTopology -> Natural
awsEksDesiredNodeCount profile topology =
  fromMaybe (awsSubstrateEksMinimumNodeCount profile) (eksNodeGroupSize topology)

-- | Sprint 4.84: create a registered stack and commit its lifecycle generation
-- in one admitted lane.
submitStackCreation
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Text.Text
  -> String
  -> ProviderRevision
  -> (ProviderRunMarker -> ProviderIntent)
  -> IO ExitCode
submitStackCreation authentication repoRoot prefix label revision buildIntent = do
  submitted <-
    submitRegisteredStackCreation authentication repoRoot prefix revision buildIntent
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
fetchAwsEksTestSnapshotFromBackend repoRoot =
  either (const Nothing) Just <$> fetchAwsEksTestSnapshotFromBackendResult repoRoot

-- | The retained @aws-eks@ outputs, with the reason when they cannot be had.
--
-- The 'Maybe' form above says only that there is no snapshot. A caller that
-- must tell an absent checkpoint from a failed read, such as the one that
-- builds a kubeconfig, needs which boundary refused: the Authority session, the
-- output read, or the decode.
fetchAwsEksTestSnapshotFromBackendResult
  :: FilePath -> IO (Either String AwsEksTestStackSnapshot)
fetchAwsEksTestSnapshotFromBackendResult repoRoot = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      ( \authentication ->
          fetchAwsEksTestSnapshotFromBackendWithAuthenticationResult authentication repoRoot
      )
  pure $ case authenticated of
    Left err ->
      Left
        ( "the Lifecycle Authority session was refused: "
            ++ renderLifecycleAuthorityAuthenticationError err
        )
    Right result -> result

fetchAwsEksTestSnapshotFromBackendWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO (Maybe AwsEksTestStackSnapshot)
fetchAwsEksTestSnapshotFromBackendWithAuthentication authentication repoRoot =
  either (const Nothing) Just
    <$> fetchAwsEksTestSnapshotFromBackendWithAuthenticationResult authentication repoRoot

fetchAwsEksTestSnapshotFromBackendWithAuthenticationResult
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO (Either String AwsEksTestStackSnapshot)
fetchAwsEksTestSnapshotFromBackendWithAuthenticationResult authentication repoRoot = do
  outputs <-
    LiveResidue.fetchPerRunStackOutputsWithAuthentication
      authentication
      repoRoot
      (StackOutputs.StackName (Text.pack awsEksTestStackName))
  pure $ case outputs of
    Left err -> Left ("the stack outputs could not be read: " ++ err)
    Right value ->
      Bifunctor.first
        ("the stack outputs could not be decoded: " ++)
        (parseAwsEksTestStackFromOutputs value)

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

-- | Why a kubeconfig for the EKS target could not be built, by the boundary that
-- refused. Each constructor carries the rendered detail of that boundary so a
-- fault is reported as the one it was: an unreadable checkpoint, a refused
-- Authority session and a refused projection once all surfaced as the same
-- "checkpoint is unavailable".
data EksKubeconfigError
  = EksKubeconfigSettingsUnavailable String
  | EksKubeconfigRegionUnavailable String
  | EksKubeconfigCheckpointUnavailable String
  | EksKubeconfigProjectionRefused String
  | EksKubeconfigPreparationFailed String
  deriving (Eq, Show)

instance Exception EksKubeconfigError where
  displayException = renderEksKubeconfigError

renderEksKubeconfigError :: EksKubeconfigError -> String
renderEksKubeconfigError err = case err of
  EksKubeconfigSettingsUnavailable detail ->
    "could not load the settings the EKS kubeconfig needs: " ++ detail
  EksKubeconfigRegionUnavailable detail ->
    "no operational AWS region for the EKS kubeconfig: " ++ detail
  EksKubeconfigCheckpointUnavailable detail ->
    "the aws-eks checkpoint could not be read: " ++ detail
  EksKubeconfigProjectionRefused detail ->
    "the EKS client-auth projection was refused: " ++ detail
  EksKubeconfigPreparationFailed detail ->
    "the ephemeral kubeconfig could not be prepared: " ++ detail

-- | Run an action with a live EKS kubeconfig, or say which boundary refused.
withEksKubeconfigResult
  :: FilePath -> (FilePath -> IO value) -> IO (Either EksKubeconfigError value)
withEksKubeconfigResult repoRoot action = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> pure (Left (EksKubeconfigSettingsUnavailable err))
    Right settings ->
      -- Sprint 1.89: the region is the parsed coordinate, so the value admitted
      -- here cannot be malformed and an unset one names its remedy.
      case requireOperationalAwsRegion settings of
        Left err -> pure (Left (EksKubeconfigRegionUnavailable err))
        Right awsRegion -> do
          snapshotResult <- fetchAwsEksTestSnapshotFromBackendResult repoRoot
          case snapshotResult of
            Left detail -> pure (Left (EksKubeconfigCheckpointUnavailable detail))
            Right snapshot ->
              projectKubeconfig (awsRegionText awsRegion) (Text.pack (eksSnapshotClusterName snapshot))
 where
  -- Sprint 7.40: routed onto the one owning module rather than restating it.
  -- This function used to build its own named pipe with a drifted mode
  -- (owner-all against the owner's read-write), its own unsupervised writer with
  -- the same proven 'ENXIO' defect, and its own kubeconfig written with none of
  -- the @O_EXCL@ / @O_NOFOLLOW@ / @CLOEXEC@ / @0600@ / fsync protections
  -- "Prodbox.Lifecycle.Teardown.EphemeralKubectl" exists to guarantee — so a
  -- pre-placed path could capture this one and could not capture that one. Two
  -- statements of a security property are two properties; this is now one.
  projectKubeconfig region clusterName = do
    projected <-
      withEksClientAuthProjection
        LifecycleAuthorityOperator
        repoRoot
        region
        clusterName
        ( \projection ->
            withEphemeralKubeconfigPath
              projection
              (runWithPrepared region clusterName projection)
        )
    pure $ case projected of
      Left err -> Left (EksKubeconfigProjectionRefused (show err))
      Right inner -> inner

  runWithPrepared region clusterName projection prepared = case prepared of
    Left unavailable -> pure (Left (EksKubeconfigPreparationFailed (show unavailable)))
    Right kubeconfigPath ->
      Right
        <$> withBearerRefresh
          repoRoot
          region
          clusterName
          kubeconfigPath
          (eksClientAuthExpiresAtEpochSeconds projection)
          (action kubeconfigPath)

-- | 'withEksKubeconfigResult' for the callers that have no error channel: the
-- refusal is raised as the typed 'EksKubeconfigError', which renders its cause,
-- rather than as an untyped 'error'.
withEksKubeconfig :: FilePath -> (FilePath -> IO value) -> IO value
withEksKubeconfig repoRoot action =
  withEksKubeconfigResult repoRoot action >>= either throwIO pure

-- | Keep the bearer behind a live kubeconfig valid for as long as the action
-- runs.
--
-- A projection's bearer lasts only the Provider's short lifetime, and a bracket
-- such as a chart deploy or a suite-long stability monitor outlives it, after
-- which every @kubectl@ invocation is rejected as unauthorized. The kubeconfig
-- names its credential by path and @kubectl@ reads that path on every
-- invocation, so a refresher that re-issues the projection and replaces the file
-- before expiry keeps the same kubeconfig usable.
withBearerRefresh
  :: FilePath
  -> Text.Text
  -> Text.Text
  -> FilePath
  -> Integer
  -> IO value
  -> IO value
withBearerRefresh repoRoot region clusterName kubeconfigPath =
  withBearerRefreshUsing
    BearerRefresher
      { refresherNow = floor <$> getPOSIXTime
      , refresherSleep = threadDelay
      , refresherRenew = renew
      , refresherReport = writeDiagnosticLine
      }
 where
  renew = do
    issued <-
      withEksClientAuthProjection
        LifecycleAuthorityOperator
        repoRoot
        region
        clusterName
        ( \fresh -> do
            replaced <- replaceEphemeralBearer kubeconfigPath fresh
            pure (eksClientAuthExpiresAtEpochSeconds fresh <$ replaced)
        )
    pure $ case issued of
      Left err -> Left (show err)
      Right (Left unavailable) -> Left (show unavailable)
      Right (Right expiry) -> Right expiry

-- | The four things a bearer refresher touches, as data, so the loop can be
-- driven by a scripted clock and issuer.
data BearerRefresher = BearerRefresher
  { refresherNow :: IO Integer
  -- ^ Seconds since the epoch.
  , refresherSleep :: Int -> IO ()
  -- ^ Microseconds.
  , refresherRenew :: IO (Either String Integer)
  -- ^ Re-issue and replace; the new bearer's expiry.
  , refresherReport :: String -> IO ()
  }

-- | Run an action while a supervised child renews the bearer.
--
-- A failed renewal is reported and retried, never fatal: the bearer in hand is
-- still valid until it expires, and the action's own failure is the louder
-- signal if it is not replaced in time. The refresher is a supervised child, so
-- if it were ever to die for a reason the loop does not absorb, that reaches the
-- action's thread instead of leaving it running on a bearer nobody is renewing.
--
-- Only synchronous failures are absorbed. The action finishing cancels the
-- refresher with an asynchronous exception and then waits for it to stop;
-- absorbing that exception, as an unrestricted handler does, would keep the
-- loop alive and make the wait — and with it the action's caller — hang for
-- as long as the loop sleeps and retries.
withBearerRefreshUsing :: BearerRefresher -> Integer -> IO value -> IO value
withBearerRefreshUsing refresher initialExpiry action =
  withSupervisedChild (refreshLoop initialExpiry) (const action)
 where
  refreshLoop expiry = do
    now <- refresherNow refresher
    refresherSleep refresher (bearerRefreshDelayMicroseconds now expiry)
    renewed <- tryNotAsync (refresherRenew refresher)
    case renewed of
      Right (Right freshExpiry) -> refreshLoop freshExpiry
      failure -> do
        refresherReport
          refresher
          ( "EKS bearer refresh failed; the credential in hand is retried before it expires: "
              ++ either show (either id show) failure
          )
        refresherSleep refresher bearerRefreshRetryMicroseconds
        refreshLoop expiry

-- | Catch a synchronous exception; let an asynchronous one propagate.
tryNotAsync :: IO result -> IO (Either SomeException result)
tryNotAsync = tryJust (\exception -> if isAsyncException exception then Nothing else Just exception)
 where
  isAsyncException exception = case fromException exception :: Maybe SomeAsyncException of
    Just _ -> True
    Nothing -> False

-- | How long to wait before re-issuing a bearer that expires at the given
-- instant: half of what remains, but never sooner than 30 seconds (a bearer
-- already near expiry is retried promptly rather than in a busy loop) and never
-- later than 20 minutes.
bearerRefreshDelayMicroseconds :: Integer -> Integer -> Int
bearerRefreshDelayMicroseconds nowSeconds expirySeconds =
  fromInteger (max 30 (min 1200 ((expirySeconds - nowSeconds) `div` 2))) * 1000000

bearerRefreshRetryMicroseconds :: Int
bearerRefreshRetryMicroseconds = 30 * 1000000

joinComma :: [String] -> String
joinComma = foldr (\value rest -> value ++ if null rest then "" else "," ++ rest) ""

failWith :: String -> IO ExitCode
failWith detail = do
  writeError (fatalError (Text.pack detail))
  pure (ExitFailure 1)
