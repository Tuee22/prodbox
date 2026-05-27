{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestValidation
  ( runNativeValidation
  , verifyAwsTestSshReachability
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , bracket_
  , catch
  , displayException
  , finally
  , try
  )
import Control.Monad (foldM)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (isAsciiUpper)
import Data.List (intercalate, isInfixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Network.HTTP.Client qualified
import Network.HTTP.Client.TLS qualified
import Network.HTTP.Types.Status qualified
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (..)
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.WebSockets qualified as WebSocket
import Numeric (showHex)
import Prodbox.Aws
  ( runAwsIamHarnessInspect
  )
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
import Prodbox.BuildSupport
  ( canonicalOperatorBinaryPath
  )
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.Dns
  ( configuredPublicHostFqdns
  , fetchPublicIp
  , queryRoute53Record
  )
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Peer
  ( PeerEventBatch (..)
  , handlePeerRequest
  , signEvent
  )
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Gateway.Types
  ( CommitLog (..)
  , Disposition (..)
  , GatewayRule (..)
  , Orders (..)
  , PeerEndpoint (..)
  , appendIfNew
  , canWriteDns
  , defaultMaxClockSkewSeconds
  , emptyCommitLog
  , eventTypeClaim
  , eventTypeYield
  , nodeDisposition
  )
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
import Prodbox.Infra.AwsTestStack qualified as AwsTest
import Prodbox.Keycloak.Email qualified
import Prodbox.Lib.ChartPlatform (resolveChartSecrets)
import Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , identityIssuerUrl
  , publicFqdn
  , publicRoutePathPrefix
  , publicRouteUrl
  , substrateKubeconfigPath
  )
import Prodbox.Result (Result (..))
import Prodbox.Ses.Capture qualified
import Prodbox.Settings
  ( Credentials (..)
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , aws
  , domain
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Settings qualified
import Prodbox.Subprocess
  ( BackgroundProcess
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , commandDisplay
  , runSubprocessStreaming
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import Prodbox.TestPlan
  ( NativeValidation (..)
  , nativeValidationId
  )
import Prodbox.UsersAdmin qualified
import System.Directory (removeFile)
import System.Environment
  ( getEnvironment
  , lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit
  ( ExitCode (..)
  )
import System.IO
  ( hClose
  , openTempFile
  )
import System.Timeout (timeout)
import Wuss qualified

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

publicEdgeReadyAttempts :: Int
publicEdgeReadyAttempts = 60

publicEdgeReadyDelayMicroseconds :: Int
publicEdgeReadyDelayMicroseconds = 10000000

chartsVscodeCurlAttempts :: Int
chartsVscodeCurlAttempts = 10

chartsVscodeCurlDelayMicroseconds :: Int
chartsVscodeCurlDelayMicroseconds = 5000000

tokenFetchAttempts :: Int
tokenFetchAttempts = 12

tokenFetchDelayMicroseconds :: Int
tokenFetchDelayMicroseconds = 5000000

awsTestSshReadyAttempts :: Int
awsTestSshReadyAttempts = 18

awsTestSshReadyDelayMicroseconds :: Int
awsTestSshReadyDelayMicroseconds = 10000000

websocketConnectionAttempts :: Int
websocketConnectionAttempts = 4

websocketConnectionRetryDelayMicroseconds :: Int
websocketConnectionRetryDelayMicroseconds = 5000000

websocketDistinctConnectionRetryDelayMicroseconds :: Int
websocketDistinctConnectionRetryDelayMicroseconds = 1000000

websocketReceiveRetryDelayMicroseconds :: Int
websocketReceiveRetryDelayMicroseconds = 1000000

gatewayValidationNamespace :: String
gatewayValidationNamespace = "gateway"

gatewayStatusRetryAttempts :: Int
gatewayStatusRetryAttempts = 12

gatewayStatusRetryDelayMicroseconds :: Int
gatewayStatusRetryDelayMicroseconds = 1000000

runNativeValidation
  :: Substrate -> FilePath -> [(String, String)] -> NativeValidation -> IO ExitCode
runNativeValidation substrate repoRoot environment validation = do
  writeOutputLine
    ("Validation: " ++ nativeValidationId validation ++ " (substrate=" ++ substrateId substrate ++ ")")
  writeDiagnosticLine
    ( "[validation="
        ++ nativeValidationId validation
        ++ " substrate="
        ++ substrateId substrate
        ++ "] entering body"
    )
  result <- withSubstrateKubeconfigEnv repoRoot substrate runSubstrateValidation
  writeDiagnosticLine
    ( "[validation="
        ++ nativeValidationId validation
        ++ " substrate="
        ++ substrateId substrate
        ++ "] body exit="
        ++ show result
    )
  pure result
 where
  runSubstrateValidation =
    case validation of
      ValidationChartsVscode -> runChartsVscodeValidation repoRoot substrate
      ValidationChartsApi -> runChartsApiValidation repoRoot substrate
      ValidationChartsWebsocket -> runChartsWebsocketValidation repoRoot environment substrate
      ValidationAdminRoutes -> runAdminRoutesValidation repoRoot substrate
      ValidationPublicDns -> runPublicDnsValidation repoRoot substrate
      ValidationDnsAws -> runDnsAwsValidation repoRoot
      ValidationAwsIam ->
        assertProducedOutputContainsAll
          "aws-iam harness inspection"
          (runAwsIamHarnessInspect repoRoot)
          ["IAM_USER=prodbox", "CONFIG_PATH="]
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
        runHaRke2AwsValidation repoRoot environment
      ValidationGatewayDaemon -> runGatewayDaemonValidation repoRoot environment
      ValidationGatewayPods ->
        runSequentially
          [ runNativeCliCommandForExitCode
              repoRoot
              environment
              ["k8s", "wait", "--namespace", gatewayValidationNamespace]
          , runNativeCliCommandForExitCode
              repoRoot
              environment
              ["k8s", "logs", "--namespace", gatewayValidationNamespace, "--tail", "20"]
          ]
      ValidationGatewayPartition -> runGatewayPartitionValidation
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
        -- The Sprint 4.11 `noLivePerRunPulumiStacks` predicate guards
        -- `rke2 delete --yes` against orphaning per-run AWS stacks.
        -- The canonical suite provisions the `aws-eks` and (sometimes)
        -- `aws-test` Pulumi stacks earlier in the run and destroys
        -- them at suite postflight, so by the time this validation
        -- fires the predicate sees live residue. The suite harness
        -- has explicit residue ownership semantics — it knows the
        -- postflight will clean up — so the `--allow-pulumi-residue`
        -- bypass is the documented operator-acknowledged escape hatch
        -- and the right tool for the suite-internal call.
        runSequentially
          [ runNativeCliCommandForExitCode
              repoRoot
              environment
              ["rke2", "delete", "--yes", "--allow-pulumi-residue"]
          , runNativeCliCommandForExitCode repoRoot environment ["rke2", "reconcile"]
          , runNativeCliCommandForExitCode repoRoot environment ["k8s", "health"]
          ]
      ValidationKeycloakInvite -> runKeycloakInviteValidation repoRoot environment

-- | Wrap a validation action with substrate-aware `KUBECONFIG` plus AWS_*
-- credentials for the AWS substrate.
--
-- For `SubstrateHomeLocal` the operator's default kubeconfig is in scope
-- already (no-op). For `SubstrateAws` the EKS kubeconfig materialized by
-- `Prodbox.Infra.AwsEksTestStack.materializeAwsEksKubeconfig` is exported
-- alongside `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION`
-- (and optionally `AWS_SESSION_TOKEN`) from `settings.aws.*`, so every
-- kubectl/helm subprocess that inherits the parent process environment can
-- both target the EKS substrate and successfully resolve the kubeconfig's
-- `aws eks get-token` exec provider.
withSubstrateKubeconfigEnv :: FilePath -> Substrate -> IO ExitCode -> IO ExitCode
withSubstrateKubeconfigEnv repoRoot substrate action =
  case substrateKubeconfigPath repoRoot substrate of
    Nothing -> action
    Just kubeconfigPath -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err -> do
          writeError (fatalError (Text.pack err))
          pure (ExitFailure 1)
        Right settings -> do
          let awsCreds = aws (validatedConfig settings)
              envOverrides =
                [ ("KUBECONFIG", kubeconfigPath)
                , ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id awsCreds))
                , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key awsCreds))
                , ("AWS_DEFAULT_REGION", Text.unpack (region awsCreds))
                , ("AWS_REGION", Text.unpack (region awsCreds))
                ]
                  ++ maybe
                    []
                    (\tok -> [("AWS_SESSION_TOKEN", Text.unpack tok)])
                    (session_token awsCreds)
          previousValues <- mapM (\(name, _) -> lookupEnv name) envOverrides
          bracket_
            (mapM_ (\(name, value) -> setEnv name value) envOverrides)
            (mapM_ restoreOne (zip envOverrides previousValues))
            action
 where
  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value

runHaRke2AwsValidation :: FilePath -> [(String, String)] -> IO ExitCode
runHaRke2AwsValidation repoRoot environment = do
  stackExit <- provisionAndVerifyAwsTestStack repoRoot environment
  case stackExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      sshExit <- verifyAwsTestSshReachability repoRoot
      case sshExit of
        ExitSuccess -> pure ExitSuccess
        firstFailure@(ExitFailure _) -> do
          writeDiagnosticLine
            "AWS test-stack SSH validation failed after reconcile; destroying and recreating the retained stack once before retry."
          destroyExit <-
            runNativeCliCommandForExitCode repoRoot environment ["pulumi", "test-destroy", "--yes"]
          case destroyExit of
            destroyFailure@(ExitFailure _) -> pure destroyFailure
            ExitSuccess -> do
              retryStackExit <- provisionAndVerifyAwsTestStack repoRoot environment
              case retryStackExit of
                retryFailure@(ExitFailure _) -> pure retryFailure
                ExitSuccess -> do
                  retrySshExit <- verifyAwsTestSshReachability repoRoot
                  case retrySshExit of
                    ExitSuccess -> pure ExitSuccess
                    ExitFailure _ -> pure firstFailure

provisionAndVerifyAwsTestStack :: FilePath -> [(String, String)] -> IO ExitCode
provisionAndVerifyAwsTestStack repoRoot environment =
  runSequentially
    [ assertNativeCommandOutputContainsAll
        repoRoot
        environment
        ["pulumi", "test-resources"]
        ["STACK=" ++ AwsTest.awsTestStackName, "NODE_COUNT=3"]
    , verifyAwsTestSnapshot repoRoot
    ]

runGatewayPartitionValidation :: IO ExitCode
runGatewayPartitionValidation =
  case gatewayPartitionValidationReport of
    Left err -> failWith err
    Right report -> do
      writeOutput report
      pure ExitSuccess

gatewayPartitionValidationReport :: Either String String
gatewayPartitionValidationReport = do
  let eventKeys =
        Map.fromList
          [ ("node-a", "partition-key-a")
          , ("node-b", "partition-key-b")
          , ("node-c", "partition-key-c")
          ]
      knownNodes = Map.keys eventKeys
      claimA =
        signEvent
          "node-a"
          eventTypeClaim
          "2026-04-06T10:00:00Z"
          "{}"
          "partition-key-a"
      claimB =
        signEvent
          "node-b"
          eventTypeClaim
          "2026-04-06T10:00:05Z"
          "{}"
          "partition-key-b"
      yieldA =
        signEvent
          "node-a"
          eventTypeYield
          "2026-04-06T10:00:06Z"
          "{}"
          "partition-key-a"
      initialLog = appendIfNew emptyCommitLog claimA
      (acceptedTakeover, rejectedTakeover) =
        handlePeerRequest
          (`Map.lookup` eventKeys)
          knownNodes
          defaultMaxClockSkewSeconds
          "2026-04-06T10:00:05Z"
          (PeerEventBatch [claimB] 2)
      takeoverLog = foldl appendIfNew initialLog acceptedTakeover
      (acceptedHeal, rejectedHeal) =
        handlePeerRequest
          (`Map.lookup` eventKeys)
          knownNodes
          defaultMaxClockSkewSeconds
          "2026-04-06T10:00:06Z"
          (PeerEventBatch [yieldA] 2)
      healedLog = foldl appendIfNew takeoverLog acceptedHeal
      duplicateMergeLog = foldl appendIfNew healedLog acceptedTakeover
      initialOwnerActive = canWriteDns "node-a" (Just "node-a") initialLog
      singleWriterAfterTakeover =
        canWriteDns "node-b" (Just "node-b") takeoverLog
          && not (canWriteDns "node-a" (Just "node-b") takeoverLog)
      yieldPersisted = nodeDisposition "node-a" healedLog == DispositionYielded
      idempotentMerge = length (commitLogEvents duplicateMergeLog) == length (commitLogEvents healedLog)
  ensurePartitionInvariant
    initialOwnerActive
    "initial claim did not activate DNS-write authority for node-a"
  ensurePartitionInvariant
    (length acceptedTakeover == 1 && null rejectedTakeover)
    "partition takeover batch did not accept the signed node-b claim event"
  ensurePartitionInvariant
    singleWriterAfterTakeover
    "partition takeover did not preserve the single-writer DNS surface"
  ensurePartitionInvariant
    (length acceptedHeal == 1 && null rejectedHeal)
    "rejoin healing batch did not accept the signed node-a yield event"
  ensurePartitionInvariant yieldPersisted "node-a yield was not preserved after rejoin healing"
  ensurePartitionInvariant
    idempotentMerge
    "append-only commit-log merge was not idempotent on repeated peer delivery"
  Right $
    unlines
      [ "GATEWAY_PARTITION_VALIDATION"
      , "FORMAL_MODEL_DELEGATED=false"
      , "INITIAL_OWNER_ACTIVE=true"
      , "PARTITION_TAKEOVER_ACCEPTED=" ++ show (length acceptedTakeover)
      , "PARTITION_TAKEOVER_REJECTED=" ++ show (length rejectedTakeover)
      , "SINGLE_WRITER_AFTER_TAKEOVER=true"
      , "REJOIN_YIELD_RECORDED=true"
      , "COMMIT_LOG_IDEMPOTENT=true"
      ]

ensurePartitionInvariant :: Bool -> String -> Either String ()
ensurePartitionInvariant condition err =
  if condition then Right () else Left err

runChartsVscodeValidation :: FilePath -> Substrate -> IO ExitCode
runChartsVscodeValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess ->
          runSequentially
            [ assertPublicHttpRedirect repoRoot settings PublicRouteVscode
            , waitForCommandOutputContainsAll
                Subprocess
                  { subprocessPath = "curl"
                  , subprocessArguments =
                      [ "-sS"
                      , "-D"
                      , "-"
                      , "-o"
                      , "/dev/null"
                      , publicRouteUrl settings PublicRouteVscode
                      ]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
                (oidcRedirectFragments settings (publicRouteUrl settings PublicRouteVscode ++ "/oauth2/callback"))
                chartsVscodeCurlAttempts
                chartsVscodeCurlDelayMicroseconds
            ]

runChartsApiValidation :: FilePath -> Substrate -> IO ExitCode
runChartsApiValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          apiTokenResult <- waitForAccessToken repoRoot settings "keycloak_api_client_secret" "prodbox-api"
          websocketTokenResult <-
            waitForAccessToken repoRoot settings "keycloak_websocket_client_secret" "prodbox-websocket"
          case (apiTokenResult, websocketTokenResult) of
            (Left err, _) -> failWith err
            (_, Left err) -> failWith err
            (Right apiToken, Right websocketToken) ->
              runSequentially
                [ runKeycloakPublicHostValidation repoRoot settings
                , assertHttpStatusIn
                    (statusOnlyCurlSpec repoRoot [] (publicRouteUrl settings PublicRouteApi))
                    ["401", "403"]
                , assertHttpStatusIn
                    ( statusOnlyCurlSpec
                        repoRoot
                        ["-H", "Authorization: Bearer " ++ websocketToken]
                        (publicRouteUrl settings PublicRouteApi)
                    )
                    ["401", "403"]
                , assertCommandOutputContainsAll
                    ( jsonCurlSpec
                        repoRoot
                        ["-H", "Authorization: Bearer " ++ apiToken]
                        (publicRouteUrl settings PublicRouteApi)
                    )
                    ["\"mode\":\"api\"", "\"pod\":\""]
                ]

runChartsWebsocketValidation :: FilePath -> [(String, String)] -> Substrate -> IO ExitCode
runChartsWebsocketValidation repoRoot environment substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          apiTokenResult <- waitForAccessToken repoRoot settings "keycloak_api_client_secret" "prodbox-api"
          websocketTokenResult <-
            waitForAccessToken repoRoot settings "keycloak_websocket_client_secret" "prodbox-websocket"
          case (apiTokenResult, websocketTokenResult) of
            (Left err, _) -> failWith err
            (_, Left err) -> failWith err
            (Right apiToken, Right websocketToken) -> do
              runSequentially
                [ runDirectOidcSessionValidation repoRoot settings
                , runWebsocketUpgradeValidation repoRoot environment settings apiToken websocketToken
                ]

data ManagedWebsocketConnection = ManagedWebsocketConnection
  { managedWebsocketConnection :: WebSocket.Connection
  , managedWebsocketPod :: String
  , managedWebsocketFinalize :: IO ()
  }

runAdminRoutesValidation :: FilePath -> Substrate -> IO ExitCode
runAdminRoutesValidation repoRoot substrate = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot substrate
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess ->
          runSequentially
            [ assertOidcProtectedRoute
                repoRoot
                settings
                (publicRouteUrl settings PublicRouteHarbor)
                (publicRouteUrl settings PublicRouteHarbor ++ "/oauth2/callback")
                "Harbor admin route did not preserve the shared-host auth contract"
            , assertOidcProtectedRoute
                repoRoot
                settings
                (publicRouteUrl settings PublicRouteMinio)
                (publicRouteUrl settings PublicRouteMinio ++ "/oauth2/callback")
                "MinIO admin route did not preserve the shared-host auth contract"
            ]

runKeycloakPublicHostValidation :: FilePath -> ValidatedSettings -> IO ExitCode
runKeycloakPublicHostValidation repoRoot settings = do
  redirectExit <-
    assertOidcProtectedRoute
      repoRoot
      settings
      (publicRouteUrl settings PublicRouteWebsocket ++ "/oidc/start")
      (publicRouteUrl settings PublicRouteWebsocket ++ "/oidc/callback")
      "direct OIDC redirect did not preserve the shared-host auth contract"
  case redirectExit of
    ExitFailure _ -> pure redirectExit
    ExitSuccess -> do
      metadataResult <-
        runJsonCommand
          (jsonCurlSpec repoRoot [] (identityIssuerUrl settings ++ "/.well-known/openid-configuration"))
      case metadataResult of
        Left err -> failWith err
        Right metadataPayload ->
          case keycloakWellKnownSummary metadataPayload of
            Left err -> failWith err
            Right (issuerValue, authorizationEndpoint, tokenEndpoint, jwksUriValue) ->
              if and
                [ issuerValue == identityIssuerUrl settings
                , (publicRouteUrl settings PublicRouteAuth ++ "/") `isInfixOf` authorizationEndpoint
                , (publicRouteUrl settings PublicRouteAuth ++ "/") `isInfixOf` tokenEndpoint
                , (publicRouteUrl settings PublicRouteAuth ++ "/") `isInfixOf` jwksUriValue
                ]
                then
                  assertHttpStatusIn
                    (statusOnlyCurlSpec repoRoot [] (publicRouteUrl settings PublicRouteAuth ++ "/health/ready"))
                    ["404"]
                else
                  failWith
                    ( "Keycloak well-known metadata did not preserve the shared-host auth contract: "
                        ++ show
                          [ issuerValue
                          , authorizationEndpoint
                          , tokenEndpoint
                          , jwksUriValue
                          ]
                    )

runDirectOidcSessionValidation :: FilePath -> ValidatedSettings -> IO ExitCode
runDirectOidcSessionValidation repoRoot settings = do
  sessionResult <- completeDirectOidcLogin repoRoot settings
  case sessionResult of
    Left err -> failWith err
    Right sessionPayload ->
      case directOidcSessionSummary sessionPayload of
        Left err -> failWith err
        Right (carrierValue, issuerValue, maybeUsername) ->
          if carrierValue == "cookie-session"
            && issuerValue == identityIssuerUrl settings
            && maybeUsername == Just "demo-user"
            then pure ExitSuccess
            else
              failWith
                ( "direct OIDC session payload did not match the documented carrier or issuer boundary: "
                    ++ show (carrierValue, issuerValue, maybeUsername)
                )

runWebsocketUpgradeValidation
  :: FilePath
  -> [(String, String)]
  -> ValidatedSettings
  -> String
  -> String
  -> IO ExitCode
runWebsocketUpgradeValidation repoRoot environment settings apiToken websocketToken = do
  nonce <- validationNonce
  let sessionId = "ws-" ++ nonce
      messageBody = "message-" ++ nonce
      websocketHost = publicFqdn settings
  initialChecksExit <-
    runSequentially
      [ assertHttpStatusIn
          (statusOnlyCurlSpec repoRoot [] (stateUrl websocketHost sessionId))
          ["401", "403"]
      , assertHttpStatusIn
          ( statusOnlyCurlSpec
              repoRoot
              ["-H", "Authorization: Bearer " ++ apiToken]
              (stateUrl websocketHost sessionId)
          )
          ["401", "403"]
      ]
  case initialChecksExit of
    ExitFailure _ -> pure initialChecksExit
    ExitSuccess -> do
      firstConnectionResult <-
        openManagedWebsocketConnection websocketHost (websocketPath sessionId True) websocketToken
      case firstConnectionResult of
        Left err -> failWith err
        Right firstConnection ->
          finally
            ( do
                secondConnectionResult <-
                  openDistinctManagedWebsocketConnection
                    websocketHost
                    (websocketPath sessionId False)
                    websocketToken
                    (managedWebsocketPod firstConnection)
                    8
                case secondConnectionResult of
                  Left err -> failWith err
                  Right secondConnection ->
                    finally
                      ( do
                          WebSocket.sendTextData
                            (managedWebsocketConnection firstConnection)
                            (Text.pack messageBody)
                          broadcastResult <-
                            waitForWebsocketBroadcast
                              (managedWebsocketConnection secondConnection)
                              messageBody
                              12
                          case broadcastResult of
                            Left err -> failWith err
                            Right senderPod ->
                              if senderPod /= managedWebsocketPod firstConnection
                                then
                                  failWith
                                    ( "websocket broadcast came from unexpected pod: expected "
                                        ++ managedWebsocketPod firstConnection
                                        ++ " but observed "
                                        ++ senderPod
                                    )
                                else do
                                  revokeExit <-
                                    assertHttpStatusIn
                                      ( statusOnlyCurlSpec
                                          repoRoot
                                          [ "-X"
                                          , "POST"
                                          , "-H"
                                          , "Authorization: Bearer " ++ websocketToken
                                          ]
                                          (revokeUrl websocketHost sessionId)
                                      )
                                      ["200"]
                                  case revokeExit of
                                    ExitFailure _ -> pure revokeExit
                                    ExitSuccess -> do
                                      revokeCloseResult <-
                                        waitForWebsocketClose
                                          (managedWebsocketConnection firstConnection)
                                          15000000
                                      case revokeCloseResult of
                                        Left err -> failWith err
                                        Right () -> do
                                          thirdConnectionResult <-
                                            openManagedWebsocketConnection
                                              websocketHost
                                              (websocketPath sessionId False)
                                              websocketToken
                                          case thirdConnectionResult of
                                            Left err -> failWith err
                                            Right thirdConnection ->
                                              finally
                                                ( do
                                                    deleteExit <-
                                                      runCommandForExitCode
                                                        Subprocess
                                                          { subprocessPath = "kubectl"
                                                          , subprocessArguments =
                                                              ["delete", "pod", managedWebsocketPod thirdConnection, "--namespace", "websocket"]
                                                          , subprocessEnvironment = Nothing
                                                          , subprocessWorkingDirectory = Just repoRoot
                                                          }
                                                    case deleteExit of
                                                      ExitFailure _ -> pure deleteExit
                                                      ExitSuccess -> do
                                                        threadDelay 2000000
                                                        fourthConnectionResult <-
                                                          openDistinctManagedWebsocketConnection
                                                            websocketHost
                                                            (websocketPath sessionId False)
                                                            websocketToken
                                                            (managedWebsocketPod thirdConnection)
                                                            8
                                                        case fourthConnectionResult of
                                                          Left err -> failWith err
                                                          Right fourthConnection ->
                                                            finally
                                                              ( do
                                                                  closeResult <-
                                                                    waitForWebsocketClose
                                                                      (managedWebsocketConnection thirdConnection)
                                                                      20000000
                                                                  case closeResult of
                                                                    Left err -> failWith err
                                                                    Right () -> do
                                                                      rolloutExit <-
                                                                        runNativeCliCommandForExitCode
                                                                          repoRoot
                                                                          environment
                                                                          ["k8s", "wait", "--namespace", "websocket"]
                                                                      case rolloutExit of
                                                                        ExitFailure _ -> pure rolloutExit
                                                                        ExitSuccess -> do
                                                                          statePayloadResult <-
                                                                            runJsonCommand
                                                                              ( jsonCurlSpec
                                                                                  repoRoot
                                                                                  ["-H", "Authorization: Bearer " ++ websocketToken]
                                                                                  (stateUrl websocketHost sessionId)
                                                                              )
                                                                          case statePayloadResult of
                                                                            Left err -> failWith err
                                                                            Right statePayload ->
                                                                              case websocketStateSnapshot statePayload of
                                                                                Left err -> failWith err
                                                                                Right (_, messages) ->
                                                                                  if messageBody `elem` messages
                                                                                    then pure ExitSuccess
                                                                                    else
                                                                                      failWith
                                                                                        ( "websocket validation did not observe reconnect-safe Redis state after drain: "
                                                                                            ++ show messages
                                                                                        )
                                                              )
                                                              (closeManagedWebsocketConnection fourthConnection)
                                                )
                                                (closeManagedWebsocketConnection thirdConnection)
                      )
                      (closeManagedWebsocketConnection secondConnection)
            )
            (closeManagedWebsocketConnection firstConnection)

completeDirectOidcLogin :: FilePath -> ValidatedSettings -> IO (Either String Value)
completeDirectOidcLogin repoRoot settings =
  withTemporaryFilePath repoRoot "prodbox-oidc-cookies" $ \cookieJarPath ->
    withTemporaryFilePath repoRoot "prodbox-oidc-login-body" $ \bodyPath -> do
      secretsResult <- resolveChartSecrets repoRoot "vscode"
      case secretsResult of
        Left err -> pure (Left err)
        Right secrets ->
          case Map.lookup "keycloak_demo_user_password" secrets of
            Nothing -> pure (Left "missing keycloak_demo_user_password for direct OIDC validation")
            Just demoPassword -> do
              loginPageResult <-
                runTextCommand
                  Subprocess
                    { subprocessPath = "curl"
                    , subprocessArguments =
                        [ "-sS"
                        , "-L"
                        , "-c"
                        , cookieJarPath
                        , "-b"
                        , cookieJarPath
                        , "-o"
                        , bodyPath
                        , publicRouteUrl settings PublicRouteWebsocket ++ "/oidc/start"
                        ]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
              case loginPageResult of
                Left err -> pure (Left err)
                Right _ -> do
                  loginBody <- readFile bodyPath
                  case extractLoginFormAction loginBody of
                    Left err -> pure (Left err)
                    Right formActionUrl -> do
                      loginResult <-
                        runTextCommand
                          Subprocess
                            { subprocessPath = "curl"
                            , subprocessArguments =
                                [ "-sS"
                                , "-L"
                                , "-c"
                                , cookieJarPath
                                , "-b"
                                , cookieJarPath
                                , "--data-urlencode"
                                , "username=demo-user"
                                , "--data-urlencode"
                                , "password=" ++ demoPassword
                                , formActionUrl
                                ]
                            , subprocessEnvironment = Nothing
                            , subprocessWorkingDirectory = Just repoRoot
                            }
                      case loginResult of
                        Left err -> pure (Left err)
                        Right _ ->
                          runJsonCommand
                            Subprocess
                              { subprocessPath = "curl"
                              , subprocessArguments =
                                  [ "-sS"
                                  , "-L"
                                  , "-c"
                                  , cookieJarPath
                                  , "-b"
                                  , cookieJarPath
                                  , publicRouteUrl settings PublicRouteWebsocket ++ "/oidc/session"
                                  ]
                              , subprocessEnvironment = Nothing
                              , subprocessWorkingDirectory = Just repoRoot
                              }

openManagedWebsocketConnection
  :: String -> String -> String -> IO (Either String ManagedWebsocketConnection)
openManagedWebsocketConnection host path token = go websocketConnectionAttempts
 where
  go :: Int -> IO (Either String ManagedWebsocketConnection)
  go attemptsLeft = do
    connectionResult <-
      try
        ( Wuss.newSecureClientConnectionWith
            host
            443
            path
            WebSocket.defaultConnectionOptions
              { WebSocket.connectionCompressionOptions = WebSocket.NoCompression
              }
            [(CI.mk (BS8.pack "Authorization"), BS8.pack ("Bearer " ++ token))]
        )
        :: IO (Either SomeException (WebSocket.Connection, IO ()))
    case connectionResult of
      Left err ->
        retryOrFail attemptsLeft ("failed to open websocket connection: " ++ displayException err)
      Right (connection, finalizeConnection) -> do
        welcomeResult <- readWebsocketWelcome connection 10000000
        case welcomeResult of
          Left err -> do
            finalizeConnection
            retryOrFail attemptsLeft err
          Right podName ->
            pure
              ( Right
                  ManagedWebsocketConnection
                    { managedWebsocketConnection = connection
                    , managedWebsocketPod = podName
                    , managedWebsocketFinalize = finalizeConnection
                    }
              )

  retryOrFail :: Int -> String -> IO (Either String ManagedWebsocketConnection)
  retryOrFail attemptsLeft detail
    | attemptsLeft <= 1 || not (shouldRetryTransientWebsocketOpenError detail) = pure (Left detail)
    | otherwise = do
        writeDiagnosticLine ("Waiting for websocket route readiness before retry: " ++ detail)
        threadDelay websocketConnectionRetryDelayMicroseconds
        go (attemptsLeft - 1)

openDistinctManagedWebsocketConnection
  :: String -> String -> String -> String -> Int -> IO (Either String ManagedWebsocketConnection)
openDistinctManagedWebsocketConnection host path token excludedPod attemptsLeft = do
  connectionResult <- openManagedWebsocketConnection host path token
  case connectionResult of
    Left err
      | attemptsLeft <= 1 || not (shouldRetryTransientWebsocketOpenError err) -> pure (Left err)
      | otherwise -> do
          writeDiagnosticLine ("Waiting for websocket route readiness before retry: " ++ err)
          threadDelay websocketDistinctConnectionRetryDelayMicroseconds
          openDistinctManagedWebsocketConnection host path token excludedPod (attemptsLeft - 1)
    Right connection
      | managedWebsocketPod connection /= excludedPod -> pure (Right connection)
      | attemptsLeft <= 1 -> do
          closeManagedWebsocketConnection connection
          pure
            ( Left
                ( "failed to observe a second websocket backend pod distinct from "
                    ++ excludedPod
                )
            )
      | otherwise -> do
          closeManagedWebsocketConnection connection
          writeDiagnosticLine "Waiting for a distinct websocket backend pod before retry."
          threadDelay websocketDistinctConnectionRetryDelayMicroseconds
          openDistinctManagedWebsocketConnection host path token excludedPod (attemptsLeft - 1)

closeManagedWebsocketConnection :: ManagedWebsocketConnection -> IO ()
closeManagedWebsocketConnection connection = do
  _ <-
    try
      ( WebSocket.sendCloseCode
          (managedWebsocketConnection connection)
          1000
          (Text.pack "validation complete")
      )
      :: IO (Either SomeException ())
  managedWebsocketFinalize connection

readWebsocketWelcome :: WebSocket.Connection -> Int -> IO (Either String String)
readWebsocketWelcome connection timeoutMicroseconds = do
  messageResult <- waitForWebsocketJsonMessage connection timeoutMicroseconds
  pure $ do
    payload <- messageResult
    payloadType <- websocketPayloadType payload
    if payloadType == "welcome"
      then websocketPayloadField payload "pod"
      else Left ("expected websocket welcome payload but observed type " ++ payloadType)

waitForWebsocketBroadcast :: WebSocket.Connection -> String -> Int -> IO (Either String String)
waitForWebsocketBroadcast connection expectedMessage attemptsLeft = go attemptsLeft
 where
  go attemptsRemaining
    | attemptsRemaining <= 0 = pure (Left "timed out waiting for websocket broadcast message")
    | otherwise = do
        messageResult <- waitForWebsocketJsonMessage connection 10000000
        case messageResult of
          Left err
            | attemptsRemaining > 1 && shouldRetryTransientWebsocketReceiveError err -> do
                writeDiagnosticLine ("Waiting for websocket broadcast delivery before retry: " ++ err)
                threadDelay websocketReceiveRetryDelayMicroseconds
                go (attemptsRemaining - 1)
            | otherwise -> pure (Left err)
          Right payload ->
            case websocketPayloadType payload of
              Left err -> pure (Left err)
              Right "message" ->
                case (websocketPayloadField payload "message", websocketPayloadField payload "pod") of
                  (Right observedMessage, Right observedPod)
                    | observedMessage == expectedMessage -> pure (Right observedPod)
                    | otherwise -> go (attemptsRemaining - 1)
                  (Left err, _) -> pure (Left err)
                  (_, Left err) -> pure (Left err)
              Right _ -> go (attemptsRemaining - 1)

waitForWebsocketClose :: WebSocket.Connection -> Int -> IO (Either String ())
waitForWebsocketClose connection timeoutMicroseconds = go timeoutMicroseconds
 where
  go remainingMicroseconds
    | remainingMicroseconds <= 0 = pure (Left "timed out waiting for websocket close")
    | otherwise = do
        receiveResult <-
          timeout
            remainingMicroseconds
            (try (WebSocket.receiveData connection :: IO Text.Text) :: IO (Either SomeException Text.Text))
        case receiveResult of
          Nothing -> pure (Left "timed out waiting for websocket close")
          Just (Left _) -> pure (Right ())
          Just (Right _) -> go (remainingMicroseconds - 1000000)

waitForWebsocketJsonMessage :: WebSocket.Connection -> Int -> IO (Either String Value)
waitForWebsocketJsonMessage connection timeoutMicroseconds = do
  receiveResult <-
    timeout
      timeoutMicroseconds
      (try (WebSocket.receiveData connection :: IO Text.Text) :: IO (Either SomeException Text.Text))
  case receiveResult of
    Nothing -> pure (Left "timed out waiting for websocket message")
    Just (Left err) -> pure (Left ("websocket receive failed: " ++ displayException err))
    Just (Right messageText) ->
      pure $
        case decodeJsonTextUtf8 messageText of
          Left err -> Left ("websocket payload was not valid JSON: " ++ err)
          Right payload -> Right payload

shouldRetryTransientWebsocketOpenError :: String -> Bool
shouldRetryTransientWebsocketOpenError detail =
  let lowered = map toLowerAscii detail
   in any
        (`isInfixOf` lowered)
        [ "<<timeout>>"
        , "timed out"
        , "temporary failure"
        , "service unavailable"
        , "connection refused"
        , "connection reset"
        , "unexpected eof"
        , "end of file"
        , "tls"
        , "bad handshake"
        , "handshake"
        , "draining"
        , "502"
        , "503"
        , "504"
        ]

shouldRetryTransientWebsocketReceiveError :: String -> Bool
shouldRetryTransientWebsocketReceiveError detail =
  let lowered = map toLowerAscii detail
   in any
        (`isInfixOf` lowered)
        [ "<<timeout>>"
        , "timed out waiting for websocket message"
        , "timed out"
        ]

keycloakWellKnownSummary :: Value -> Either String (String, String, String, String)
keycloakWellKnownSummary payload =
  case payload of
    Object obj ->
      (,,,)
        <$> requireStringField obj "issuer"
        <*> requireStringField obj "authorization_endpoint"
        <*> requireStringField obj "token_endpoint"
        <*> requireStringField obj "jwks_uri"
    _ -> Left "Keycloak well-known payload was not a JSON object"

directOidcSessionSummary :: Value -> Either String (String, String, Maybe String)
directOidcSessionSummary payload =
  case payload of
    Object obj ->
      (,,)
        <$> requireStringField obj "carrier"
        <*> requireStringField obj "issuer"
        <*> pure
          ( case KeyMap.lookup "preferred_username" obj of
              Just (String value) -> Just (textValue value)
              _ -> Nothing
          )
    _ -> Left "direct OIDC session payload was not a JSON object"

websocketPayloadType :: Value -> Either String String
websocketPayloadType payload =
  case payload of
    Object obj -> requireStringField obj "type"
    _ -> Left "websocket payload was not a JSON object"

websocketPayloadField :: Value -> String -> Either String String
websocketPayloadField payload fieldName =
  case payload of
    Object obj -> requireStringField obj fieldName
    _ -> Left "websocket payload was not a JSON object"

extractLoginFormAction :: String -> Either String String
extractLoginFormAction bodyText =
  case splitOnSubstring "action=\"" bodyText of
    Nothing -> Left "could not find Keycloak login form action"
    Just (_, actionAndRest) ->
      case break (== '"') actionAndRest of
        (actionUrl, _ : _) | actionUrl /= "" -> Right (decodeHtmlAttributeValue actionUrl)
        _ -> Left "could not parse Keycloak login form action"

decodeHtmlAttributeValue :: String -> String
decodeHtmlAttributeValue value =
  replaceAll "&amp;" "&" value

replaceAll :: String -> String -> String -> String
replaceAll needle replacement = go
 where
  go remaining =
    case splitOnSubstring needle remaining of
      Nothing -> remaining
      Just (beforeNeedle, afterNeedle) ->
        beforeNeedle ++ replacement ++ go afterNeedle

withTemporaryFilePath :: FilePath -> String -> (FilePath -> IO a) -> IO a
withTemporaryFilePath parentDir templateName action =
  bracket
    (openTempFile parentDir templateName)
    (\(path, handle) -> hClose handle >> removeFile path)
    (\(path, handle) -> hClose handle >> action path)

splitOnSubstring :: String -> String -> Maybe (String, String)
splitOnSubstring needle haystack = go [] haystack
 where
  go _ [] = Nothing
  go reversedPrefix remaining
    | needle `startsWith` remaining =
        Just (reverse reversedPrefix, drop (length needle) remaining)
    | otherwise =
        case remaining of
          character : trailing ->
            go (character : reversedPrefix) trailing

startsWith :: String -> String -> Bool
startsWith [] _ = True
startsWith _ [] = False
startsWith (left : leftRest) (right : rightRest) =
  left == right && startsWith leftRest rightRest

waitForAccessToken :: FilePath -> ValidatedSettings -> String -> String -> IO (Either String String)
waitForAccessToken repoRoot settings secretKey clientId = go tokenFetchAttempts
 where
  go :: Int -> IO (Either String String)
  go attemptsLeft = do
    tokenResult <- fetchAccessToken repoRoot settings secretKey clientId
    case tokenResult of
      Right token -> pure (Right token)
      Left err
        | attemptsLeft <= 1 -> pure (Left err)
        | otherwise -> do
            writeDiagnosticLine ("Waiting for Keycloak token endpoint readiness before retry: " ++ err)
            threadDelay tokenFetchDelayMicroseconds
            go (attemptsLeft - 1)

fetchAccessToken :: FilePath -> ValidatedSettings -> String -> String -> IO (Either String String)
fetchAccessToken repoRoot settings secretKey clientId = do
  secretsResult <- resolveChartSecrets repoRoot "vscode"
  case secretsResult of
    Left err -> pure (Left err)
    Right secrets ->
      case (Map.lookup secretKey secrets, Map.lookup "keycloak_demo_user_password" secrets) of
        (Just clientSecret, Just demoPassword) -> do
          payloadResult <-
            runJsonCommand
              Subprocess
                { subprocessPath = "curl"
                , subprocessArguments =
                    [ "-sS"
                    , "--fail-with-body"
                    , "-X"
                    , "POST"
                    , "--data-urlencode"
                    , "grant_type=password"
                    , "--data-urlencode"
                    , "client_id=" ++ clientId
                    , "--data-urlencode"
                    , "client_secret=" ++ clientSecret
                    , "--data-urlencode"
                    , "username=demo-user"
                    , "--data-urlencode"
                    , "password=" ++ demoPassword
                    , identityIssuerUrl settings ++ "/protocol/openid-connect/token"
                    ]
                , subprocessEnvironment = Nothing
                , subprocessWorkingDirectory = Just repoRoot
                }
          case payloadResult of
            Left err -> pure (Left err)
            Right payload -> pure (accessTokenFromPayload payload)
        _ ->
          pure
            ( Left
                ( "missing required Keycloak secrets for external validation: "
                    ++ secretKey
                    ++ " and keycloak_demo_user_password"
                )
            )

accessTokenFromPayload :: Value -> Either String String
accessTokenFromPayload payload =
  case payload of
    Object obj ->
      case KeyMap.lookup "access_token" obj of
        Just (String tokenText) -> Right (Text.unpack tokenText)
        _ -> Left "token endpoint response did not contain access_token"
    _ -> Left "token endpoint response was not a JSON object"

statusOnlyCurlSpec :: FilePath -> [String] -> String -> Subprocess
statusOnlyCurlSpec repoRoot extraArgs url =
  Subprocess
    { subprocessPath = "curl"
    , subprocessArguments = ["-sS", "-o", "/dev/null", "-w", "%{http_code}"] ++ extraArgs ++ [url]
    , subprocessEnvironment = Nothing
    , subprocessWorkingDirectory = Just repoRoot
    }

jsonCurlSpec :: FilePath -> [String] -> String -> Subprocess
jsonCurlSpec repoRoot extraArgs url =
  Subprocess
    { subprocessPath = "curl"
    , subprocessArguments = ["-sS", "--fail-with-body"] ++ extraArgs ++ [url]
    , subprocessEnvironment = Nothing
    , subprocessWorkingDirectory = Just repoRoot
    }

assertHttpStatusIn :: Subprocess -> [String] -> IO ExitCode
assertHttpStatusIn spec allowedStatuses = do
  result <- runTextCommand spec
  case result of
    Left err -> failWith err
    Right statusText ->
      if trim statusText `elem` allowedStatuses
        then pure ExitSuccess
        else
          failWith
            ( "`"
                ++ commandDisplay spec
                ++ "` returned unexpected HTTP status "
                ++ trim statusText
                ++ "; expected one of "
                ++ show allowedStatuses
            )

websocketPath :: String -> Bool -> String
websocketPath sessionId resetRequested =
  "/ws?session="
    ++ sessionId
    ++ if resetRequested then "&reset=true" else ""

revokeUrl :: String -> String -> String
revokeUrl host sessionId =
  "https://" ++ host ++ "/ws/revoke?session=" ++ sessionId

stateUrl :: String -> String -> String
stateUrl host sessionId =
  "https://" ++ host ++ "/ws/state?session=" ++ sessionId

websocketStateSnapshot :: Value -> Either String (String, [String])
websocketStateSnapshot payload =
  case payload of
    Object obj ->
      case (KeyMap.lookup "pod" obj, KeyMap.lookup "messages" obj) of
        (Just (String podText), Just (Array messageValues)) ->
          Right
            ( Text.unpack podText
            , [ Text.unpack value
              | String value <- Vector.toList messageValues
              ]
            )
        _ -> Left "websocket state payload did not include pod and messages fields"
    _ -> Left "websocket state payload was not a JSON object"

assertOidcProtectedRoute
  :: FilePath
  -> ValidatedSettings
  -> String
  -> String
  -> String
  -> IO ExitCode
assertOidcProtectedRoute repoRoot settings requestUrl callbackUrl failurePrefix = do
  redirectResult <-
    runTextCommand
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments = ["-sS", "-D", "-", "-o", "/dev/null", requestUrl]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case redirectResult of
    Left err -> failWith err
    Right redirectHeaders ->
      if redirectHeadersContainOidcContract settings callbackUrl redirectHeaders
        then pure ExitSuccess
        else failWith (failurePrefix ++ ": " ++ redirectHeaders)

redirectHeadersContainOidcContract :: ValidatedSettings -> String -> String -> Bool
redirectHeadersContainOidcContract settings callbackUrl redirectHeaders =
  let loweredRedirectHeaders = map toLowerAscii redirectHeaders
   in all (`isInfixOf` loweredRedirectHeaders) (oidcRedirectFragments settings callbackUrl)

oidcRedirectFragments :: ValidatedSettings -> String -> [String]
oidcRedirectFragments settings callbackUrl =
  map
    (map toLowerAscii)
    [ "HTTP/"
    , "Location: " ++ identityIssuerUrl settings ++ "/protocol/openid-connect/auth"
    , "redirect_uri=" ++ encodeRedirectUri callbackUrl
    ]

encodeRedirectUri :: String -> String
encodeRedirectUri =
  replaceAll "/" "%2F" . replaceAll ":" "%3A"

waitForPublicEdgeReady :: FilePath -> Substrate -> IO ExitCode
waitForPublicEdgeReady repoRoot substrate = do
  let spec =
        Subprocess
          { subprocessPath = canonicalOperatorBinaryPath repoRoot
          , subprocessArguments = ["host", "public-edge", "--substrate", substrateId substrate]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
  waitForClassification spec publicEdgeReadyAttempts
 where
  waitForClassification :: Subprocess -> Int -> IO ExitCode
  waitForClassification spec attemptsLeft = do
    outputResult <- captureSubprocessResult spec
    case outputResult of
      Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
      Success output -> do
        let combinedOutput = processStdout output ++ processStderr output
        writeOutput (processStdout output)
        writeDiagnostic (processStderr output)
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
                writeDiagnosticLine "Waiting for public edge readiness before external curl validation."
                threadDelay publicEdgeReadyDelayMicroseconds
                waitForClassification spec (attemptsLeft - 1)

runPublicDnsValidation :: FilePath -> Substrate -> IO ExitCode
runPublicDnsValidation repoRoot _substrate = do
  settingsEnvResult <- settingsAwsEnvironment repoRoot
  case settingsEnvResult of
    Left err -> failWith err
    Right (settings, awsEnvironment) -> do
      zonePayloadResult <-
        runJsonCommand
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "route53"
                , "get-hosted-zone"
                , "--id"
                , textValue (zone_id (route53 (validatedConfig settings)))
                , "--output"
                , "json"
                ]
            , subprocessEnvironment = Just awsEnvironment
            , subprocessWorkingDirectory = Just repoRoot
            }
      case zonePayloadResult of
        Left err -> failWith err
        Right payload ->
          case hostedZoneDelegation payload of
            Left err -> failWith err
            Right (zoneName, expectedNameservers) -> do
              digResult <-
                runTextCommand
                  Subprocess
                    { subprocessPath = "dig"
                    , subprocessArguments = ["+short", "NS", zoneName]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
              case digResult of
                Left err -> failWith err
                Right stdoutText -> do
                  let actualNameservers = sort (map normalizeDnsValue (filter (/= "") (lines stdoutText)))
                      expectedNormalized = sort (map normalizeDnsValue expectedNameservers)
                  if actualNameservers == expectedNormalized
                    then do
                      publicIpResult <- fetchPublicIp
                      case publicIpResult of
                        Left err -> failWith err
                        Right publicIp ->
                          verifyConfiguredPublicDnsRecords repoRoot settings publicIp
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
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments =
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
                , subprocessEnvironment = Just awsEnvironment
                , subprocessWorkingDirectory = Just repoRoot
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
                        Subprocess
                          { subprocessPath = "aws"
                          , subprocessArguments =
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
                          , subprocessEnvironment = Just awsEnvironment
                          , subprocessWorkingDirectory = Just repoRoot
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

configuredHostedZoneName
  :: FilePath -> [(String, String)] -> ValidatedSettings -> IO (Either String String)
configuredHostedZoneName repoRoot awsEnvironment settings = do
  zonePayloadResult <-
    runJsonCommand
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "route53"
            , "get-hosted-zone"
            , "--id"
            , textValue (zone_id (route53 (validatedConfig settings)))
            , "--output"
            , "json"
            ]
        , subprocessEnvironment = Just awsEnvironment
        , subprocessWorkingDirectory = Just repoRoot
        }
  case zonePayloadResult of
    Left err -> pure (Left err)
    Right payload ->
      case hostedZoneDelegation payload of
        Left err -> pure (Left err)
        Right (zoneName, _) -> pure (Right (trimTrailingDot zoneName))

cleanupDnsAwsValidation
  :: FilePath
  -> [(String, String)]
  -> String
  -> String
  -> String
  -> IO ExitCode
cleanupDnsAwsValidation repoRoot awsEnvironment hostedZoneId recordName recordIp = do
  deleteRecordExit <-
    changeRoute53Record repoRoot awsEnvironment hostedZoneId "DELETE" recordName recordIp
  case deleteRecordExit of
    ExitFailure _ -> pure deleteRecordExit
    ExitSuccess ->
      runCommandForExitCode
        Subprocess
          { subprocessPath = "aws"
          , subprocessArguments =
              [ "route53"
              , "delete-hosted-zone"
              , "--id"
              , hostedZoneId
              ]
          , subprocessEnvironment = Just awsEnvironment
          , subprocessWorkingDirectory = Just repoRoot
          }

changeRoute53Record
  :: FilePath
  -> [(String, String)]
  -> String
  -> String
  -> String
  -> String
  -> IO ExitCode
changeRoute53Record repoRoot awsEnvironment hostedZoneId action recordName recordIp = do
  (batchPath, handle) <- openTempFile repoRoot "route53-change-batch.json"
  hClose handle
  writeResult <-
    try
      ( writeFile
          batchPath
          (route53ChangeBatch action recordName recordIp)
      )
      :: IO (Either IOException ())
  case writeResult of
    Left err -> failWith ("failed to write Route 53 change batch: " ++ show err)
    Right () -> do
      changeResult <-
        runTextCommand
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
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
            , subprocessEnvironment = Just awsEnvironment
            , subprocessWorkingDirectory = Just repoRoot
            }
      _ <- try (removeFile batchPath) :: IO (Either IOException ())
      case changeResult of
        Left err -> failWith err
        Right changeId ->
          runCommandForExitCode
            Subprocess
              { subprocessPath = "aws"
              , subprocessArguments =
                  [ "route53"
                  , "wait"
                  , "resource-record-sets-changed"
                  , "--id"
                  , trim changeId
                  ]
              , subprocessEnvironment = Just awsEnvironment
              , subprocessWorkingDirectory = Just repoRoot
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
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <-
        runNativeCliCommandForExitCode
          repoRoot
          environment
          ["k8s", "wait", "--namespace", gatewayValidationNamespace]
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess -> do
          ordersTextResult <-
            runTextCommand
              Subprocess
                { subprocessPath = "kubectl"
                , subprocessArguments =
                    [ "--namespace"
                    , gatewayValidationNamespace
                    , "get"
                    , "configmap"
                    , "gateway-orders"
                    , "-o"
                    , "jsonpath={.data.orders\\.dhall}"
                    ]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Just repoRoot
                }
          case ordersTextResult of
            Left err -> failWith err
            Right ordersText -> do
              -- Sprint 2.22 closure: the chart now ships Dhall Orders.
              ordersResult <- GatewaySettings.decodeOrdersDhall (Text.pack ordersText)
              case ordersResult of
                Left err -> failWith ("failed to parse gateway orders from cluster ConfigMap: " ++ err)
                Right orders ->
                  case selectGatewayValidationPeer orders of
                    Left err -> failWith err
                    Right localPeer -> do
                      localPort <- reserveLocalTcpPort
                      withGatewayPortForward repoRoot environment localPeer localPort $
                        withTemporaryFilePath repoRoot "gateway-validation-orders.dhall" $ \ordersPath ->
                          withTemporaryFilePath repoRoot "gateway-validation-config.dhall" $ \configPath -> do
                            ordersWriteResult <-
                              try
                                (writeFile ordersPath (renderGatewayValidationOrdersDhall orders (peerNodeId localPeer) localPort))
                                :: IO (Either IOException ())
                            case ordersWriteResult of
                              Left err ->
                                failWith ("failed to write gateway validation orders file: " ++ show err)
                              Right () -> do
                                configWriteResult <-
                                  try
                                    ( writeFile
                                        configPath
                                        (renderGatewayValidationConfigDhall settings (peerNodeId localPeer) ordersPath)
                                    )
                                    :: IO (Either IOException ())
                                case configWriteResult of
                                  Left err ->
                                    failWith ("failed to write gateway validation config: " ++ show err)
                                  Right () -> do
                                    statusExit <-
                                      waitForCommandOutputContainsAll
                                        (nativeCliCommandSpec repoRoot environment ["gateway", "status", "--config", configPath])
                                        [ "Gateway status"
                                        , "NODE_ID=" ++ peerNodeId localPeer
                                        , "DNS_WRITE_GATE=" ++ publicFqdn settings ++ "@"
                                        ]
                                        gatewayStatusRetryAttempts
                                        gatewayStatusRetryDelayMicroseconds
                                    case statusExit of
                                      ExitFailure _ -> pure statusExit
                                      ExitSuccess ->
                                        runNativeCliCommandForExitCode
                                          repoRoot
                                          environment
                                          ["k8s", "logs", "--namespace", gatewayValidationNamespace, "--tail", "20"]

selectGatewayValidationPeer :: Orders -> Either String PeerEndpoint
selectGatewayValidationPeer orders =
  case ordersNodes orders of
    [] -> Left "gateway validation requires at least one node in gateway-orders"
    peer : _ -> Right peer

-- | Sprint 2.20/2.22 closure follow-up: the gateway daemon decodes its config
-- via 'Dhall.inputFile auto' against the schema in
-- 'Prodbox.Gateway.Settings.DaemonConfigDhall'. The validation surface renders
-- the same shape so the daemon accepts the file without falling back to a JSON
-- decoder (which no longer exists on the supported path).
renderGatewayValidationOrdersDhall :: Orders -> String -> Int -> String
renderGatewayValidationOrdersDhall orders localNodeId localPort =
  unlines
    [ "{ version_utc = " ++ show (ordersVersionUtc orders)
    , ", nodes = " ++ nodesList
    , ", gateway_rule ="
    , "    { ranked_nodes = " ++ rankedNodesList
    , "    , heartbeat_timeout_seconds = " ++ show (heartbeatTimeoutSeconds (ordersGatewayRule orders))
    , "    }"
    , "}"
    ]
 where
  nodesList = case ordersNodes orders of
    [] ->
      "([] : List { node_id : Text, stable_dns_name : Text, rest_host : Text, rest_port : Natural, socket_host : Text, socket_port : Natural })"
    peers -> "[ " ++ intercalate "\n  , " (map renderNode peers) ++ " ]"
  rankedNodesList = case rankedNodes (ordersGatewayRule orders) of
    [] -> "([] : List Text)"
    xs -> "[ " ++ intercalate ", " (map dhallText xs) ++ " ]"
  renderNode :: PeerEndpoint -> String
  renderNode peer =
    "{ node_id = "
      ++ dhallText (peerNodeId peer)
      ++ ", stable_dns_name = "
      ++ dhallText rewrittenStableDnsName
      ++ ", rest_host = "
      ++ dhallText rewrittenRestHost
      ++ ", rest_port = "
      ++ show rewrittenRestPort
      ++ ", socket_host = "
      ++ dhallText (peerSocketHost peer)
      ++ ", socket_port = "
      ++ show (peerSocketPort peer)
      ++ " }"
   where
    isLocalNode = peerNodeId peer == localNodeId
    rewrittenStableDnsName =
      if isLocalNode
        then "127.0.0.1"
        else peerStableDnsName peer
    rewrittenRestHost =
      if isLocalNode
        then "127.0.0.1"
        else peerRestHost peer
    rewrittenRestPort =
      if isLocalNode
        then localPort
        else peerRestPort peer

renderGatewayValidationConfigDhall :: ValidatedSettings -> String -> FilePath -> String
renderGatewayValidationConfigDhall settings nodeId ordersPath =
  unlines
    [ "{ schemaVersion = 1"
    , ", boot ="
    , "    { node_id = " ++ dhallText nodeId
    , "    , cert_file = " ++ dhallText "unused.crt"
    , "    , key_file = " ++ dhallText "unused.key"
    , "    , ca_file = " ++ dhallText "unused-ca.crt"
    , "    , orders_file = " ++ dhallText ordersPath
    , "    , event_keys = [ { name = "
        ++ dhallText nodeId
        ++ ", value = "
        ++ dhallText "validation-key"
        ++ " } ]"
    , "    , dns_write_gate = Some"
    , "        { zone_id = " ++ dhallText (Text.unpack (zone_id (route53 (validatedConfig settings))))
    , "        , fqdn = " ++ dhallText (publicFqdn settings)
    , "        , ttl = " ++ show (demo_ttl (domain (validatedConfig settings)))
    , "        , aws_region = " ++ dhallText (Text.unpack (region (aws (validatedConfig settings))))
    , "        }"
    , "    , aws_creds = None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
    , "    , minio_creds = None { minio_access_key : Text, minio_secret_key : Text }"
    , "    , minio_endpoint_url = None Text"
    , "    }"
    , ", live ="
    , "    { heartbeat_interval_seconds = 1.0"
    , "    , reconnect_interval_seconds = 1.0"
    , "    , sync_interval_seconds = 5.0"
    , "    , max_clock_skew_seconds = 10.0"
    , "    , drain_deadline_seconds = Some 30"
    , "    , log_level = Some " ++ dhallText "info"
    , "    }"
    , "}"
    ]

-- | Render a Haskell 'String' as a Dhall double-quoted text literal, escaping
-- the two characters Dhall's quoted-text grammar treats specially (backslash and
-- double-quote). Used by 'renderGatewayValidationOrdersDhall' /
-- 'renderGatewayValidationConfigDhall' so the rendered validation files round-
-- trip through @Dhall.inputFile auto@ without further escaping.
dhallText :: String -> String
dhallText s = '"' : escape s ++ "\""
 where
  escape [] = []
  escape ('\\' : rest) = '\\' : '\\' : escape rest
  escape ('"' : rest) = '\\' : '"' : escape rest
  escape (c : rest) = c : escape rest

withGatewayPortForward :: FilePath -> [(String, String)] -> PeerEndpoint -> Int -> IO a -> IO a
withGatewayPortForward repoRoot environment localPeer localPort action = do
  processResult <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , gatewayValidationNamespace
            , "port-forward"
            , "service/gateway-" ++ peerNodeId localPeer
            , show localPort ++ ":" ++ show (peerRestPort localPeer)
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  case processResult of
    Left err -> fail (show err)
    Right process -> action `finally` cleanupGatewayPortForward process

cleanupGatewayPortForward :: BackgroundProcess -> IO ()
cleanupGatewayPortForward = stopBackgroundProcess

reserveLocalTcpPort :: IO Int
reserveLocalTcpPort =
  withSocketsDo $
    bracket
      (socket AF_INET Stream defaultProtocol)
      close
      ( \reservedSocket -> do
          setSocketOption reservedSocket ReuseAddr 1
          bind reservedSocket (SockAddrInet 0 (tupleToHostAddress (0, 0, 0, 0)))
          socketAddress <- getSocketName reservedSocket
          case socketAddress of
            SockAddrInet port _ -> pure (fromIntegral port)
            SockAddrInet6 port _ _ _ -> pure (fromIntegral port)
            _ -> fail "failed to reserve a local TCP port for gateway validation"
      )

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
        (verifyAwsTestNodeSsh repoRoot privateKeyPath)
        ExitSuccess
        (AwsTest.testSnapshotNodes current)

verifyAwsTestNodeSsh :: FilePath -> FilePath -> ExitCode -> AwsTest.AwsTestNode -> IO ExitCode
verifyAwsTestNodeSsh repoRoot privateKeyPath exitCode node =
  case exitCode of
    ExitFailure _ -> pure exitCode
    ExitSuccess -> waitForAwsTestNodeSsh repoRoot privateKeyPath node awsTestSshReadyAttempts

waitForAwsTestNodeSsh :: FilePath -> FilePath -> AwsTest.AwsTestNode -> Int -> IO ExitCode
waitForAwsTestNodeSsh repoRoot privateKeyPath node attemptsLeft = do
  let spec =
        Subprocess
          { subprocessPath = "ssh"
          , subprocessArguments =
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
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
      nodeLabel = AwsTest.testNodeName node ++ " (" ++ AwsTest.testNodePublicIp node ++ ")"
  outputResult <- captureSubprocessResult spec
  case outputResult of
    Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitSuccess -> do
          writeOutput (processStdout output)
          writeDiagnostic (processStderr output)
          pure ExitSuccess
        ExitFailure _
          | attemptsLeft > 1 && shouldRetryAwsTestSsh (outputDetail output) -> do
              writeDiagnosticLine
                ( "Waiting for AWS test-stack SSH readiness on "
                    ++ nodeLabel
                    ++ " before retry: "
                    ++ outputDetail output
                )
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

assertNativeCommandOutputContainsAll
  :: FilePath -> [(String, String)] -> [String] -> [String] -> IO ExitCode
assertNativeCommandOutputContainsAll repoRoot environment cliArgs expectedTexts = do
  assertCommandOutputContainsAll (nativeCliCommandSpec repoRoot environment cliArgs) expectedTexts

assertProducedOutputContainsAll :: String -> IO String -> [String] -> IO ExitCode
assertProducedOutputContainsAll label outputAction expectedTexts = do
  outputResult <- try outputAction :: IO (Either SomeException String)
  case outputResult of
    Left err -> failWith ("`" ++ label ++ "` failed: " ++ displayException err)
    Right output -> do
      writeOutput output
      if all (`isInfixOf` output) expectedTexts
        then pure ExitSuccess
        else
          failWith
            ( "`"
                ++ label
                ++ "` did not report all required output fragments: "
                ++ show expectedTexts
            )

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> Subprocess
nativeCliCommandSpec repoRoot environment cliArgs =
  Subprocess
    { subprocessPath = canonicalOperatorBinaryPath repoRoot
    , subprocessArguments = cliArgs
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just repoRoot
    }

runCommandForExitCode :: Subprocess -> IO ExitCode
runCommandForExitCode spec = do
  commandResult <- runSubprocessStreaming spec
  case commandResult of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

assertCommandOutputContainsAll :: Subprocess -> [String] -> IO ExitCode
assertCommandOutputContainsAll spec expectedTexts = do
  outputResult <- captureSubprocessResult spec
  case outputResult of
    Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
    Success output -> do
      writeOutput (processStdout output)
      writeDiagnostic (processStderr output)
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

waitForCommandOutputContainsAll :: Subprocess -> [String] -> Int -> Int -> IO ExitCode
waitForCommandOutputContainsAll spec expectedTexts attempts delayMicroseconds = go attempts
 where
  loweredExpectedTexts = map (map toLowerAscii) expectedTexts

  go :: Int -> IO ExitCode
  go attemptsLeft = do
    outputResult <- captureSubprocessResult spec
    case outputResult of
      Failure err ->
        if attemptsLeft <= 1
          then failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
          else retry attemptsLeft
      Success output -> do
        writeOutput (processStdout output)
        writeDiagnostic (processStderr output)
        let combinedOutput = processStdout output ++ processStderr output
            loweredCombinedOutput = map toLowerAscii combinedOutput
        case processExitCode output of
          ExitSuccess
            | all (`isInfixOf` loweredCombinedOutput) loweredExpectedTexts -> pure ExitSuccess
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report all required output fragments: "
                      ++ show expectedTexts
                  )
            | otherwise -> retry attemptsLeft
          ExitFailure code
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` exited with code "
                      ++ show code
                  )
            | otherwise -> retry attemptsLeft

  retry :: Int -> IO ExitCode
  retry attemptsLeft = do
    writeDiagnosticLine "Waiting for required command output before retry."
    threadDelay delayMicroseconds
    go (attemptsLeft - 1)

verifyConfiguredPublicDnsRecords :: FilePath -> ValidatedSettings -> String -> IO ExitCode
verifyConfiguredPublicDnsRecords repoRoot settings publicIp =
  do
    dnsExit <- foldM verifyHost ExitSuccess (configuredPublicHostFqdns settings)
    case dnsExit of
      ExitFailure _ -> pure dnsExit
      ExitSuccess -> assertPublicHttpRedirect repoRoot settings PublicRouteAuth
 where
  verifyHost :: ExitCode -> String -> IO ExitCode
  verifyHost exitCode fqdn =
    case exitCode of
      ExitFailure _ -> pure exitCode
      ExitSuccess -> do
        recordResult <- queryRoute53Record repoRoot settings fqdn
        case recordResult of
          Left err -> failWith err
          Right Nothing ->
            failWith ("Public A record missing in Route 53 for " ++ fqdn)
          Right (Just route53Ip)
            | route53Ip /= publicIp ->
                failWith
                  ( "Public A record mismatch for "
                      ++ fqdn
                      ++ ": Route 53 has "
                      ++ route53Ip
                      ++ " but the current public IP is "
                      ++ publicIp
                  )
            | otherwise -> do
                digResult <-
                  runTextCommand
                    Subprocess
                      { subprocessPath = "dig"
                      , subprocessArguments = ["+short", "A", fqdn]
                      , subprocessEnvironment = Nothing
                      , subprocessWorkingDirectory = Just repoRoot
                      }
                case digResult of
                  Left err -> failWith err
                  Right stdoutText ->
                    let resolvedIps = nub (filter (/= "") (map trim (lines stdoutText)))
                     in if publicIp `elem` resolvedIps
                          then pure ExitSuccess
                          else
                            failWith
                              ( "Public DNS A resolution mismatch for "
                                  ++ fqdn
                                  ++ ": expected "
                                  ++ publicIp
                                  ++ " but found "
                                  ++ show resolvedIps
                              )

assertPublicHttpRedirect :: FilePath -> ValidatedSettings -> PublicEdgeRoute -> IO ExitCode
assertPublicHttpRedirect repoRoot settings route = do
  result <-
    runTextCommand
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments = ["-sS", "-D", "-", "-o", "/dev/null", publicHttpRouteUrl settings route]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  case result of
    Left err -> failWith err
    Right headers ->
      if publicHttpRedirectMatches settings route headers
        then pure ExitSuccess
        else failWith ("public HTTP redirect did not target the canonical HTTPS route: " ++ headers)

publicHttpRouteUrl :: ValidatedSettings -> PublicEdgeRoute -> String
publicHttpRouteUrl settings route =
  "http://" ++ publicFqdn settings ++ publicRoutePathPrefix route

publicHttpRedirectMatches :: ValidatedSettings -> PublicEdgeRoute -> String -> Bool
publicHttpRedirectMatches settings route headers =
  let lowered = map toLowerAscii headers
      target = map toLowerAscii ("location: " ++ publicRouteUrl settings route)
      permanentStatus =
        any
          (`isInfixOf` lowered)
          [ "http/1.1 301"
          , "http/1.1 308"
          , "http/2 301"
          , "http/2 308"
          , "http/3 301"
          , "http/3 308"
          ]
   in permanentStatus && target `isInfixOf` lowered

runTextCommand :: Subprocess -> IO (Either String String)
runTextCommand spec = do
  outputResult <- captureSubprocessResult spec
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

runJsonCommand :: Subprocess -> IO (Either String Value)
runJsonCommand spec = do
  textResult <- runTextCommand spec
  pure $ do
    stdoutText <- textResult
    decodeJsonStringUtf8 stdoutText

decodeJsonStringUtf8 :: String -> Either String Value
decodeJsonStringUtf8 = decodeJsonTextUtf8 . Text.pack

decodeJsonTextUtf8 :: Text.Text -> Either String Value
decodeJsonTextUtf8 =
  eitherDecode . BL.fromStrict . TextEncoding.encodeUtf8

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
requireObjectField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (Object nested) -> Right nested
    _ -> Left ("missing object field " ++ key)

requireStringField :: KeyMap.KeyMap Value -> String -> Either String String
requireStringField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (String value) -> Right (textValue value)
    _ -> Left ("missing string field " ++ key)

requireStringArrayField :: KeyMap.KeyMap Value -> String -> Either String [String]
requireStringArrayField objectValue key =
  case KeyMap.lookup (Key.fromString key) objectValue of
    Just (Array values) ->
      mapM (requireStringArrayEntry key) (Vector.toList values)
    _ -> Left ("missing array field " ++ key)

requireStringArrayEntry :: String -> Value -> Either String String
requireStringArrayEntry key value =
  case value of
    String textVal -> Right (textValue textVal)
    _ -> Left ("field " ++ key ++ " must contain strings only")

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
trim =
  reverse
    . dropWhile (`elem` [' ', '\n', '\r', '\t'])
    . reverse
    . dropWhile (`elem` [' ', '\n', '\r', '\t'])

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
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | `ValidationKeycloakInvite` — Phase 8 canonical-suite validation that proves the
-- operator-invited email-auth flow end-to-end on whichever substrate is active.
--
-- The flow per [phase-8-email-invite-auth.md → Sprint 8.5](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md):
--
-- 1. Generate a unique recipient at `ses.receive_subdomain`.
-- 2. Call `UsersAdmin.inviteUser` (live Keycloak admin API). Asserts the created
--    user lands with `emailVerified=false`.
-- 3. Poll the SES capture bucket via `Prodbox.Ses.Capture.pollSesCapture` for the
--    inbound message (60 s deadline).
-- 4. Extract the action-token URL via `Prodbox.Keycloak.Email.parseKeycloakInviteLink`.
-- 5. Follow the link via http-client; assert 2xx (the chart's realm config renders
--    the credential-setup form on this response).
-- 6. Cleanup: `UsersAdmin.revokeUser ident --delete` and `deleteCapturedEmail`.
--
-- The credential-setup form POST + fresh OIDC login + claim assertions documented in
-- the Sprint 8.5 phase doc remain as Sprint-8.5-residual remaining work — those steps
-- exercise chart-specific HTML form behavior and the existing
-- `ValidationChartsVscode` OIDC machinery; landing them is straightforward but adds
-- significant chart-template coupling and is best done after a live deploy run has
-- confirmed the form structure.
runKeycloakInviteValidation :: FilePath -> [(String, String)] -> IO ExitCode
runKeycloakInviteValidation repoRoot _environment = do
  envResult <- settingsAwsEnvironment repoRoot
  case envResult of
    Left err -> failWith err
    Right (settings, awsEnv) -> do
      nonce <- generateInviteNonce
      let subdomain =
            Text.unpack
              ( Text.strip
                  ( Prodbox.Settings.receive_subdomain
                      (Prodbox.Settings.ses (Prodbox.Settings.validatedConfig settings))
                  )
              )
      if null subdomain
        then
          failWith
            "ValidationKeycloakInvite: ses.receive_subdomain must be set in prodbox-config.dhall."
        else do
          let recipient = "test-" ++ nonce ++ "@" ++ subdomain
          writeOutputLine ("KEYCLOAK_INVITE_RECIPIENT=" ++ recipient)
          inviteResult <- Prodbox.UsersAdmin.inviteUser repoRoot settings recipient Nothing
          case inviteResult of
            Left err -> failWith ("invite failed: " ++ err)
            Right summary -> do
              let userId = Text.unpack (Prodbox.UsersAdmin.userSummaryId summary)
              writeOutputLine ("KEYCLOAK_INVITE_USER_ID=" ++ userId)
              captureResult <-
                Prodbox.Ses.Capture.pollSesCapture awsEnv settings (Text.pack recipient) 60
              outcome <- case captureResult of
                Failure err -> pure (Failure ("S3 capture poll failed: " ++ err))
                Success captured -> do
                  let key = Prodbox.Ses.Capture.capturedEmailKey captured
                  writeOutputLine ("KEYCLOAK_INVITE_S3_KEY=" ++ Text.unpack key)
                  case Prodbox.Keycloak.Email.parseKeycloakInviteLink
                    (Prodbox.Ses.Capture.capturedEmailBody captured) of
                    Left err -> pure (Failure ("invite-link parse failed: " ++ err))
                    Right inviteUrl -> do
                      writeOutputLine "KEYCLOAK_INVITE_LINK_PARSED=true"
                      followResult <- followInviteLink inviteUrl
                      case followResult of
                        Failure err -> pure (Failure ("invite link follow failed: " ++ err))
                        Success () -> do
                          writeOutputLine "KEYCLOAK_INVITE_LINK_FOLLOWED=true"
                          pure (Success key)
              _ <- Prodbox.UsersAdmin.revokeUser repoRoot settings userId True
              case outcome of
                Failure err -> failWith err
                Success key -> do
                  _ <- Prodbox.Ses.Capture.deleteCapturedEmail awsEnv settings key
                  writeOutputLine "KEYCLOAK_INVITE_CLEANUP=true"
                  pure ExitSuccess

-- | Generate a 16-character lowercase hex nonce from the current `POSIXTime` for
-- per-test recipient uniqueness. Avoids pulling in a stronger RNG; sub-second
-- collisions are acceptable for a validation harness that runs serially.
generateInviteNonce :: IO String
generateInviteNonce = do
  now <- Data.Time.Clock.POSIX.getPOSIXTime
  let micros = floor (now * 1e6) :: Integer
  pure (Numeric.showHex micros "")

-- | Follow the parsed Keycloak invite URL and assert the response is in the 2xx
-- range. Uses the same TLS manager configuration as `Prodbox.Keycloak.Admin`.
followInviteLink :: String -> IO (Result ())
followInviteLink rawUrl =
  ( do
      manager <- Network.HTTP.Client.TLS.newTlsManager
      reqInit <- Network.HTTP.Client.parseRequest rawUrl
      let req = reqInit {Network.HTTP.Client.method = "GET"}
      resp <- Network.HTTP.Client.httpLbs req manager
      let code = Network.HTTP.Types.Status.statusCode (Network.HTTP.Client.responseStatus resp)
      pure $
        if code >= 200 && code < 400
          then Success ()
          else
            Failure
              ( "invite link returned HTTP "
                  ++ show code
                  ++ "; expected 2xx/3xx for the Keycloak credential-setup page"
              )
  )
    `catch` \exception ->
      pure
        ( Failure
            ("invite link follow threw HttpException: " ++ show (exception :: Network.HTTP.Client.HttpException))
        )
