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
  , displayException
  , finally
  , try
  )
import Control.Monad (foldM)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (isAsciiUpper)
import Data.List (isInfixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
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
import Prodbox.Aws
  ( runAwsIamHarnessInspect
  )
import Prodbox.AwsEnvironment
  ( overlayAwsCredentials
  )
import Prodbox.BuildSupport
  ( canonicalOperatorBinaryPath
  )
import Prodbox.Dns
  ( configuredPublicHostFqdns
  , fetchPublicIp
  , queryRoute53Record
  )
import Prodbox.Gateway.Peer
  ( PeerEventBatch (..)
  , handlePeerRequest
  , signEvent
  )
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
  , parseOrders
  )
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
import Prodbox.Infra.AwsTestStack qualified as AwsTest
import Prodbox.Lib.ChartPlatform (resolveChartSecrets)
import Prodbox.PublicEdge
  ( PublicEdgeRoute (..)
  , identityIssuerUrl
  , publicFqdn
  , publicRouteUrl
  )
import Prodbox.Result (Result (..))
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
import Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  , commandDisplay
  , runStreamingCommand
  )
import Prodbox.TestPlan
  ( NativeValidation (..)
  , nativeValidationId
  )
import System.Directory (removeFile)
import System.Environment
  ( getEnvironment
  )
import System.Exit
  ( ExitCode (..)
  )
import System.IO
  ( hClose
  , hPutStr
  , hPutStrLn
  , openTempFile
  , stderr
  )
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , createProcess
  , proc
  , terminateProcess
  , waitForProcess
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

runNativeValidation :: FilePath -> [(String, String)] -> NativeValidation -> IO ExitCode
runNativeValidation repoRoot environment validation = do
  putStrLn ("Validation: " ++ nativeValidationId validation)
  case validation of
    ValidationChartsVscode -> runChartsVscodeValidation repoRoot
    ValidationChartsApi -> runChartsApiValidation repoRoot
    ValidationChartsWebsocket -> runChartsWebsocketValidation repoRoot environment
    ValidationAdminRoutes -> runAdminRoutesValidation repoRoot
    ValidationPublicDns -> runPublicDnsValidation repoRoot
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
      runSequentially
        [ runNativeCliCommandForExitCode repoRoot environment ["rke2", "delete", "--yes"]
        , runNativeCliCommandForExitCode repoRoot environment ["rke2", "install"]
        , runNativeCliCommandForExitCode repoRoot environment ["k8s", "health"]
        ]

runGatewayPartitionValidation :: IO ExitCode
runGatewayPartitionValidation =
  case gatewayPartitionValidationReport of
    Left err -> failWith err
    Right report -> do
      putStr report
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

runChartsVscodeValidation :: FilePath -> IO ExitCode
runChartsVscodeValidation repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot
      case readyExit of
        ExitFailure _ -> pure readyExit
        ExitSuccess ->
          waitForCommandOutputContainsAll
            CommandSpec
              { commandPath = "curl"
              , commandArguments =
                  [ "-sS"
                  , "-D"
                  , "-"
                  , "-o"
                  , "/dev/null"
                  , publicRouteUrl settings PublicRouteVscode
                  ]
              , commandEnvironment = Nothing
              , commandWorkingDirectory = Just repoRoot
              }
            (oidcRedirectFragments settings (publicRouteUrl settings PublicRouteVscode ++ "/oauth2/callback"))
            chartsVscodeCurlAttempts
            chartsVscodeCurlDelayMicroseconds

runChartsApiValidation :: FilePath -> IO ExitCode
runChartsApiValidation repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot
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

runChartsWebsocketValidation :: FilePath -> [(String, String)] -> IO ExitCode
runChartsWebsocketValidation repoRoot environment = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot
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

runAdminRoutesValidation :: FilePath -> IO ExitCode
runAdminRoutesValidation repoRoot = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> do
      readyExit <- waitForPublicEdgeReady repoRoot
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
                                                        CommandSpec
                                                          { commandPath = "kubectl"
                                                          , commandArguments =
                                                              ["delete", "pod", managedWebsocketPod thirdConnection, "--namespace", "websocket"]
                                                          , commandEnvironment = Nothing
                                                          , commandWorkingDirectory = Just repoRoot
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
                  CommandSpec
                    { commandPath = "curl"
                    , commandArguments =
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
                    , commandEnvironment = Nothing
                    , commandWorkingDirectory = Just repoRoot
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
                          CommandSpec
                            { commandPath = "curl"
                            , commandArguments =
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
                            , commandEnvironment = Nothing
                            , commandWorkingDirectory = Just repoRoot
                            }
                      case loginResult of
                        Left err -> pure (Left err)
                        Right _ ->
                          runJsonCommand
                            CommandSpec
                              { commandPath = "curl"
                              , commandArguments =
                                  [ "-sS"
                                  , "-L"
                                  , "-c"
                                  , cookieJarPath
                                  , "-b"
                                  , cookieJarPath
                                  , publicRouteUrl settings PublicRouteWebsocket ++ "/oidc/session"
                                  ]
                              , commandEnvironment = Nothing
                              , commandWorkingDirectory = Just repoRoot
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
        hPutStrLn stderr ("Waiting for websocket route readiness before retry: " ++ detail)
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
          hPutStrLn stderr ("Waiting for websocket route readiness before retry: " ++ err)
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
          hPutStrLn stderr "Waiting for a distinct websocket backend pod before retry."
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
                hPutStrLn stderr ("Waiting for websocket broadcast delivery before retry: " ++ err)
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
            hPutStrLn stderr ("Waiting for Keycloak token endpoint readiness before retry: " ++ err)
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
              CommandSpec
                { commandPath = "curl"
                , commandArguments =
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
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Just repoRoot
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

statusOnlyCurlSpec :: FilePath -> [String] -> String -> CommandSpec
statusOnlyCurlSpec repoRoot extraArgs url =
  CommandSpec
    { commandPath = "curl"
    , commandArguments = ["-sS", "-o", "/dev/null", "-w", "%{http_code}"] ++ extraArgs ++ [url]
    , commandEnvironment = Nothing
    , commandWorkingDirectory = Just repoRoot
    }

jsonCurlSpec :: FilePath -> [String] -> String -> CommandSpec
jsonCurlSpec repoRoot extraArgs url =
  CommandSpec
    { commandPath = "curl"
    , commandArguments = ["-sS", "--fail-with-body"] ++ extraArgs ++ [url]
    , commandEnvironment = Nothing
    , commandWorkingDirectory = Just repoRoot
    }

assertHttpStatusIn :: CommandSpec -> [String] -> IO ExitCode
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
      CommandSpec
        { commandPath = "curl"
        , commandArguments = ["-sS", "-D", "-", "-o", "/dev/null", requestUrl]
        , commandEnvironment = Nothing
        , commandWorkingDirectory = Just repoRoot
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

configuredHostedZoneName
  :: FilePath -> [(String, String)] -> ValidatedSettings -> IO (Either String String)
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
          ( route53ChangeBatch action recordName recordIp
          )
      )
      :: IO (Either IOException ())
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
              CommandSpec
                { commandPath = "kubectl"
                , commandArguments =
                    [ "--namespace"
                    , gatewayValidationNamespace
                    , "get"
                    , "configmap"
                    , "gateway-orders"
                    , "-o"
                    , "jsonpath={.data.orders\\.json}"
                    ]
                , commandEnvironment = Just environment
                , commandWorkingDirectory = Just repoRoot
                }
          case ordersTextResult of
            Left err -> failWith err
            Right ordersText ->
              case parseOrders ordersText of
                Left err -> failWith ("failed to parse gateway orders from cluster ConfigMap: " ++ err)
                Right orders ->
                  case selectGatewayValidationPeer orders of
                    Left err -> failWith err
                    Right localPeer -> do
                      localPort <- reserveLocalTcpPort
                      withGatewayPortForward repoRoot environment localPeer localPort $
                        withTemporaryFilePath repoRoot "gateway-validation-orders.json" $ \ordersPath ->
                          withTemporaryFilePath repoRoot "gateway-validation-config.json" $ \configPath -> do
                            ordersWriteResult <-
                              try
                                (BL.writeFile ordersPath (renderGatewayValidationOrders orders (peerNodeId localPeer) localPort))
                                :: IO (Either IOException ())
                            case ordersWriteResult of
                              Left err ->
                                failWith ("failed to write gateway validation orders file: " ++ show err)
                              Right () -> do
                                configWriteResult <-
                                  try
                                    ( BL.writeFile
                                        configPath
                                        (renderGatewayValidationConfig settings (peerNodeId localPeer) ordersPath)
                                    )
                                    :: IO (Either IOException ())
                                case configWriteResult of
                                  Left err ->
                                    failWith ("failed to write gateway validation config: " ++ show err)
                                  Right () -> do
                                    statusExit <-
                                      waitForCommandOutputContainsAll
                                        (nativeCliCommandSpec repoRoot environment ["gateway", "status", configPath])
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

renderGatewayValidationOrders :: Orders -> String -> Int -> BL.ByteString
renderGatewayValidationOrders orders localNodeId localPort =
  encode $
    object
      [ "version_utc" .= ordersVersionUtc orders
      , "nodes" .= map renderNode (ordersNodes orders)
      , "gateway_rule"
          .= object
            [ "ranked_nodes" .= rankedNodes (ordersGatewayRule orders)
            , "heartbeat_timeout_seconds" .= heartbeatTimeoutSeconds (ordersGatewayRule orders)
            ]
      ]
 where
  renderNode :: PeerEndpoint -> Value
  renderNode peer =
    object
      [ "node_id" .= peerNodeId peer
      , "stable_dns_name" .= rewrittenStableDnsName
      , "rest_host" .= rewrittenRestHost
      , "rest_port" .= rewrittenRestPort
      , "socket_host" .= peerSocketHost peer
      , "socket_port" .= peerSocketPort peer
      ]
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

renderGatewayValidationConfig :: ValidatedSettings -> String -> FilePath -> BL.ByteString
renderGatewayValidationConfig settings nodeId ordersPath =
  encode $
    object
      [ "node_id" .= nodeId
      , "cert_file" .= ("unused.crt" :: String)
      , "key_file" .= ("unused.key" :: String)
      , "ca_file" .= ("unused-ca.crt" :: String)
      , "orders_file" .= ordersPath
      , "event_keys"
          .= Object
            (KeyMap.singleton (Key.fromString nodeId) (String "validation-key"))
      , "heartbeat_interval_seconds" .= (1.0 :: Double)
      , "reconnect_interval_seconds" .= (1.0 :: Double)
      , "sync_interval_seconds" .= (5.0 :: Double)
      , "dns_write_gate"
          .= object
            [ "zone_id" .= textValue (zone_id (route53 (validatedConfig settings)))
            , "fqdn" .= publicFqdn settings
            , "ttl" .= (fromIntegral (demo_ttl (domain (validatedConfig settings))) :: Integer)
            , "aws_region" .= textValue (region (aws (validatedConfig settings)))
            ]
      ]

withGatewayPortForward :: FilePath -> [(String, String)] -> PeerEndpoint -> Int -> IO a -> IO a
withGatewayPortForward repoRoot environment localPeer localPort action = do
  (_, _, _, processHandle) <-
    createProcess
      ( proc
          "kubectl"
          [ "--namespace"
          , gatewayValidationNamespace
          , "port-forward"
          , "service/gateway-" ++ peerNodeId localPeer
          , show localPort ++ ":" ++ show (peerRestPort localPeer)
          ]
      )
        { env = Just environment
        , cwd = Just repoRoot
        }
  action `finally` cleanupGatewayPortForward processHandle

cleanupGatewayPortForward :: ProcessHandle -> IO ()
cleanupGatewayPortForward processHandle = do
  _ <- try (terminateProcess processHandle) :: IO (Either SomeException ())
  _ <- try (waitForProcess processHandle) :: IO (Either SomeException ExitCode)
  pure ()

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
              hPutStrLn
                stderr
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

waitForCommandOutputContainsAll :: CommandSpec -> [String] -> Int -> Int -> IO ExitCode
waitForCommandOutputContainsAll spec expectedTexts attempts delayMicroseconds = go attempts
 where
  loweredExpectedTexts = map (map toLowerAscii) expectedTexts

  go :: Int -> IO ExitCode
  go attemptsLeft = do
    outputResult <- captureCommand spec
    case outputResult of
      Failure err ->
        if attemptsLeft <= 1
          then failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
          else retry attemptsLeft
      Success output -> do
        putStr (processStdout output)
        hPutStr stderr (processStderr output)
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
    hPutStrLn stderr "Waiting for required command output before retry."
    threadDelay delayMicroseconds
    go (attemptsLeft - 1)

verifyConfiguredPublicDnsRecords :: FilePath -> ValidatedSettings -> String -> IO ExitCode
verifyConfiguredPublicDnsRecords repoRoot settings publicIp =
  foldM verifyHost ExitSuccess (configuredPublicHostFqdns settings)
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
                    CommandSpec
                      { commandPath = "dig"
                      , commandArguments = ["+short", "A", fqdn]
                      , commandEnvironment = Nothing
                      , commandWorkingDirectory = Just repoRoot
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
  hPutStrLn stderr message
  pure (ExitFailure 1)
