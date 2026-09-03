{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Loopback-only host access to the dedicated home Lifecycle Authority.
--
-- The service identity, namespace, and remote port are compiled coordinates;
-- callers receive only a role-indexed client and cannot substitute a generic
-- endpoint.  The bracket binds the home RKE2 kubeconfig explicitly, so an AWS
-- substrate's temporary ambient context cannot redirect retained authority
-- traffic.
module Prodbox.ControlPlane.LocalClient
  ( -- * Per-role remote ports (Sprint 3.35)

  --   All five are the one compiled 'controlPlaneListenPort'; exported so the
  --   unit suite can pin that against the constants rather than in a comment.
    authorityBackupForwardTarget
  , authorityBackupRemotePort
  , lifecycleAuthorityForwardTarget
  , lifecycleAuthorityRemotePort
  , providerWorkerForwardTarget
  , providerWorkerRemotePort
  , targetSecretAgentForwardTarget
  , targetSecretAgentRemotePort
  , tlsRetentionForwardTarget
  , tlsRetentionRemotePort
  , localClientStartupProbePath
  , LocalLifecycleAuthorityError (..)
  , renderLocalLifecycleAuthorityError
  , withLocalLifecycleAuthorityClient
  , withLocalLifecycleAuthorityAuthenticatedTransport
  , withLocalLifecycleAuthorityRetainedDeliveryAuthenticatedTransport
  , withLocalLifecycleAuthorityTlsWorkflowAuthenticatedTransport
  , lifecycleAuthorityHttpConfig
  , lifecycleAuthorityRetainedDeliveryHttpConfig
  , lifecycleAuthorityTlsWorkflowHttpConfig
  , LocalProviderWorkerError (..)
  , renderLocalProviderWorkerError
  , withLocalProviderWorkerClient
  , withLocalProviderWorkerAuthenticatedTransport
  , LocalTargetSecretAgentError (..)
  , renderLocalTargetSecretAgentError
  , withLocalTargetSecretAgentClient
  , withLocalTargetSecretAgentAuthenticatedTransport
  , withTargetSecretAgentClientUsingEnvironment
  , withTargetSecretAgentAuthenticatedTransportUsingEnvironment
  , LocalAuthorityBackupError (..)
  , AuthorityBackupForwardStartupObservation (..)
  , classifyAuthorityBackupForwardStartup
  , continueAuthorityBackupForwardAfterStartupWith
  , renderLocalAuthorityBackupError
  , retryAuthorityBackupForwardWith
  , withLocalAuthorityBackupClient
  , withLocalAuthorityBackupAuthenticatedTransport
  , LocalTlsRetentionError (..)
  , renderLocalTlsRetentionError
  , withLocalTlsRetentionClient
  , withLocalTlsRetentionAuthenticatedTransport
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, displayException, try)
import Data.Text qualified as Text
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
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
import Prodbox.Capacity.RetainedMaterialDeliveryBudget qualified as RetainedMaterialDeliveryBudget
import Prodbox.Capacity.TlsRetentionWorkflowBudget qualified as TlsRetentionWorkflowBudget
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneClientError
  , mkAuthorityBackupEndpoint
  , mkLifecycleAuthorityEndpoint
  , mkProviderWorkerEndpoint
  , mkTargetSecretAgentEndpoint
  , mkTlsRetentionEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.Error (errorMsg)
import Prodbox.Http.Client
  ( HttpConfig (..)
  , defaultHttpConfig
  , httpRequestNoBody
  , renderHttpError
  )
import Prodbox.Infra.MinioBackend (resolveLocalKubeconfig)
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Subprocess
  ( BackgroundProcess (..)
  , Subprocess (..)
  , startBackgroundProcess
  , stopBackgroundProcess
  )
import System.Environment (getEnvironment)
import System.IO (hGetLine)
import System.Timeout (timeout)

data LocalLifecycleAuthorityError
  = LocalLifecycleAuthorityKubeconfigFailed !String
  | LocalLifecycleAuthorityPortReservationFailed !String
  | LocalLifecycleAuthorityProcessStartFailed !String
  | LocalLifecycleAuthorityReadinessFailed !String
  | LocalLifecycleAuthorityClientInvalid !ControlPlaneClientError
  deriving stock (Eq, Show)

renderLocalLifecycleAuthorityError :: LocalLifecycleAuthorityError -> String
renderLocalLifecycleAuthorityError err = case err of
  LocalLifecycleAuthorityKubeconfigFailed detail ->
    "resolve home Lifecycle Authority kubeconfig: " ++ detail
  LocalLifecycleAuthorityPortReservationFailed detail ->
    "reserve Lifecycle Authority loopback port: " ++ detail
  LocalLifecycleAuthorityProcessStartFailed detail ->
    "start Lifecycle Authority Service port-forward: " ++ detail
  LocalLifecycleAuthorityReadinessFailed detail ->
    "Lifecycle Authority Service is not ready: " ++ detail
  LocalLifecycleAuthorityClientInvalid detail ->
    "construct Lifecycle Authority client: " ++ show detail

withLocalLifecycleAuthorityClient
  :: (ControlPlaneClient 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withLocalLifecycleAuthorityClient =
  withLocalLifecycleAuthorityClientUsing lifecycleAuthorityClient

withLocalLifecycleAuthorityClientUsing
  :: ( Int
       -> Either
            ControlPlaneClientError
            (ControlPlaneClient 'LifecycleAuthorityRuntime)
     )
  -> (ControlPlaneClient 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withLocalLifecycleAuthorityClientUsing buildClient action = do
  kubeconfigResult <- resolveLocalKubeconfig
  case kubeconfigResult of
    Left detail -> pure (Left (LocalLifecycleAuthorityKubeconfigFailed detail))
    Right kubeconfig -> do
      portResult <- reserveLoopbackPort
      case portResult of
        Left detail ->
          pure (Left (LocalLifecycleAuthorityPortReservationFailed detail))
        Right localPort -> do
          environment <- homeKubectlEnvironment kubeconfig
          bracket
            (startForward environment localPort)
            cleanupForward
            (runWithForward localPort)
 where
  runWithForward _ (Left err) = pure (Left err)
  runWithForward localPort (Right _) = do
    ready <- waitUntilStartupProbe LifecycleAuthorityRuntime localPort readinessAttempts
    case ready of
      Left detail ->
        pure (Left (LocalLifecycleAuthorityReadinessFailed detail))
      Right () ->
        case buildClient localPort of
          Left err -> pure (Left (LocalLifecycleAuthorityClientInvalid err))
          Right client -> Right <$> action client

-- | Open the same loopback-only connection but expose only the complete
-- authenticated transport.  Signer, scope, epoch, deadline, and durable nonce
-- ownership are explicit caller inputs; this boundary never invents them from
-- host state.
withLocalLifecycleAuthorityAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withLocalLifecycleAuthorityAuthenticatedTransport bounds providers action =
  withLocalLifecycleAuthorityClient
    (action . mkAuthenticatedClientTransport bounds providers)

-- | Open the same exact Authority endpoint with only the response budget of
-- the retained-delivery route widened to contain its persisted operation.
withLocalLifecycleAuthorityRetainedDeliveryAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withLocalLifecycleAuthorityRetainedDeliveryAuthenticatedTransport bounds providers action =
  withLocalLifecycleAuthorityClientUsing
    lifecycleAuthorityRetainedDeliveryClient
    (action . mkAuthenticatedClientTransport bounds providers)

-- | Open the same exact Authority endpoint with only the response budget of
-- the closed TLS retention workflow widened to contain its longest program.
withLocalLifecycleAuthorityTlsWorkflowAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withLocalLifecycleAuthorityTlsWorkflowAuthenticatedTransport bounds providers action =
  withLocalLifecycleAuthorityClientUsing
    lifecycleAuthorityTlsWorkflowClient
    (action . mkAuthenticatedClientTransport bounds providers)

data LocalProviderWorkerError
  = LocalProviderWorkerKubeconfigFailed !String
  | LocalProviderWorkerPortReservationFailed !String
  | LocalProviderWorkerProcessStartFailed !String
  | LocalProviderWorkerReadinessFailed !String
  | LocalProviderWorkerClientInvalid !ControlPlaneClientError
  deriving stock (Eq, Show)

renderLocalProviderWorkerError :: LocalProviderWorkerError -> String
renderLocalProviderWorkerError err = case err of
  LocalProviderWorkerKubeconfigFailed detail ->
    "resolve home Provider Worker kubeconfig: " ++ detail
  LocalProviderWorkerPortReservationFailed detail ->
    "reserve Provider Worker loopback port: " ++ detail
  LocalProviderWorkerProcessStartFailed detail ->
    "start Provider Worker Service port-forward: " ++ detail
  LocalProviderWorkerReadinessFailed detail ->
    "Provider Worker Service is not ready: " ++ detail
  LocalProviderWorkerClientInvalid detail ->
    "construct Provider Worker client: " ++ show detail

withLocalProviderWorkerClient
  :: (ControlPlaneClient 'ProviderWorkerRuntime -> IO value)
  -> IO (Either LocalProviderWorkerError value)
withLocalProviderWorkerClient action = do
  kubeconfigResult <- resolveLocalKubeconfig
  case kubeconfigResult of
    Left detail -> pure (Left (LocalProviderWorkerKubeconfigFailed detail))
    Right kubeconfig -> do
      portResult <- reserveLoopbackPort
      case portResult of
        Left detail -> pure (Left (LocalProviderWorkerPortReservationFailed detail))
        Right localPort -> do
          environment <- homeKubectlEnvironment kubeconfig
          bracket
            (startProviderForward environment localPort)
            cleanupProviderForward
            (runWithProviderForward localPort)
 where
  runWithProviderForward _ (Left err) = pure (Left err)
  runWithProviderForward localPort (Right _) = do
    ready <- waitUntilStartupProbe ProviderWorkerRuntime localPort readinessAttempts
    case ready of
      Left detail -> pure (Left (LocalProviderWorkerReadinessFailed detail))
      Right () -> case providerWorkerClient localPort of
        Left err -> pure (Left (LocalProviderWorkerClientInvalid err))
        Right client -> Right <$> action client

withLocalProviderWorkerAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'ProviderWorkerRuntime -> IO value)
  -> IO (Either LocalProviderWorkerError value)
withLocalProviderWorkerAuthenticatedTransport bounds providers action =
  withLocalProviderWorkerClient
    (action . mkAuthenticatedClientTransport bounds providers)

data LocalTargetSecretAgentError
  = LocalTargetSecretAgentKubeconfigFailed !String
  | LocalTargetSecretAgentPortReservationFailed !String
  | LocalTargetSecretAgentProcessStartFailed !String
  | LocalTargetSecretAgentReadinessFailed !String
  | LocalTargetSecretAgentClientInvalid !ControlPlaneClientError
  deriving stock (Eq, Show)

renderLocalTargetSecretAgentError :: LocalTargetSecretAgentError -> String
renderLocalTargetSecretAgentError err = case err of
  LocalTargetSecretAgentKubeconfigFailed detail ->
    "resolve home Target Secret Agent kubeconfig: " ++ detail
  LocalTargetSecretAgentPortReservationFailed detail ->
    "reserve Target Secret Agent loopback port: " ++ detail
  LocalTargetSecretAgentProcessStartFailed detail ->
    "start Target Secret Agent Service port-forward: " ++ detail
  LocalTargetSecretAgentReadinessFailed detail ->
    "Target Secret Agent Service is not ready: " ++ detail
  LocalTargetSecretAgentClientInvalid detail ->
    "construct Target Secret Agent client: " ++ show detail

withLocalTargetSecretAgentClient
  :: (ControlPlaneClient 'TargetSecretAgentRuntime -> IO value)
  -> IO (Either LocalTargetSecretAgentError value)
withLocalTargetSecretAgentClient action = do
  kubeconfigResult <- resolveLocalKubeconfig
  case kubeconfigResult of
    Left detail -> pure (Left (LocalTargetSecretAgentKubeconfigFailed detail))
    Right kubeconfig -> do
      environment <- homeKubectlEnvironment kubeconfig
      withTargetSecretAgentClientUsingEnvironment environment action

withTargetSecretAgentClientUsingEnvironment
  :: [(String, String)]
  -> (ControlPlaneClient 'TargetSecretAgentRuntime -> IO value)
  -> IO (Either LocalTargetSecretAgentError value)
withTargetSecretAgentClientUsingEnvironment environment action = do
  portResult <- reserveLoopbackPort
  case portResult of
    Left detail ->
      pure (Left (LocalTargetSecretAgentPortReservationFailed detail))
    Right localPort ->
      bracket
        (startTargetForward environment localPort)
        cleanupTargetForward
        (runWithTargetForward localPort)
 where
  runWithTargetForward _ (Left err) = pure (Left err)
  runWithTargetForward localPort (Right _) = do
    ready <- waitUntilStartupProbe TargetSecretAgentRuntime localPort readinessAttempts
    case ready of
      Left detail ->
        pure (Left (LocalTargetSecretAgentReadinessFailed detail))
      Right () ->
        case targetSecretAgentClient localPort of
          Left err -> pure (Left (LocalTargetSecretAgentClientInvalid err))
          Right client -> Right <$> action client

withLocalTargetSecretAgentAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'TargetSecretAgentRuntime -> IO value)
  -> IO (Either LocalTargetSecretAgentError value)
withLocalTargetSecretAgentAuthenticatedTransport bounds providers action =
  withLocalTargetSecretAgentClient
    (action . mkAuthenticatedClientTransport bounds providers)

withTargetSecretAgentAuthenticatedTransportUsingEnvironment
  :: [(String, String)]
  -> AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'TargetSecretAgentRuntime -> IO value)
  -> IO (Either LocalTargetSecretAgentError value)
withTargetSecretAgentAuthenticatedTransportUsingEnvironment environment bounds providers action =
  withTargetSecretAgentClientUsingEnvironment
    environment
    (action . mkAuthenticatedClientTransport bounds providers)

data LocalAuthorityBackupError
  = LocalAuthorityBackupKubeconfigFailed !String
  | LocalAuthorityBackupPortReservationFailed !String
  | LocalAuthorityBackupProcessStartFailed !String
  | LocalAuthorityBackupLivenessFailed !String
  | LocalAuthorityBackupClientInvalid !ControlPlaneClientError
  deriving stock (Eq, Show)

data AuthorityBackupForwardStartupObservation
  = AuthorityBackupForwardStartupTimedOut
  | AuthorityBackupForwardStartupReadFailed
  | AuthorityBackupForwardStartupLine !String
  deriving stock (Eq, Show)

renderLocalAuthorityBackupError :: LocalAuthorityBackupError -> String
renderLocalAuthorityBackupError err = case err of
  LocalAuthorityBackupKubeconfigFailed detail ->
    "resolve home Authority Backup kubeconfig: " ++ detail
  LocalAuthorityBackupPortReservationFailed detail ->
    "reserve Authority Backup loopback port: " ++ detail
  LocalAuthorityBackupProcessStartFailed detail ->
    "start Authority Backup Deployment port-forward: " ++ detail
  LocalAuthorityBackupLivenessFailed detail ->
    "Authority Backup listener is not live: " ++ detail
  LocalAuthorityBackupClientInvalid detail ->
    "construct Authority Backup client: " ++ show detail

withLocalAuthorityBackupClient
  :: (ControlPlaneClient 'AuthorityBackupRuntime -> IO value)
  -> IO (Either LocalAuthorityBackupError value)
withLocalAuthorityBackupClient action = do
  kubeconfigResult <- resolveLocalKubeconfig
  case kubeconfigResult of
    Left detail -> pure (Left (LocalAuthorityBackupKubeconfigFailed detail))
    Right kubeconfig -> do
      portResult <- reserveLoopbackPort
      case portResult of
        Left detail ->
          pure (Left (LocalAuthorityBackupPortReservationFailed detail))
        Right localPort -> do
          environment <- homeKubectlEnvironment kubeconfig
          retryAuthorityBackupForwardWith
            readinessAttempts
            (threadDelay 250000)
            (startAuthorityBackupForward environment localPort)
            cleanupAuthorityBackupForward
            (runWithAuthorityBackupForward localPort)
 where
  runWithAuthorityBackupForward localPort process =
    continueAuthorityBackupForwardAfterStartupWith
      (waitForAuthorityBackupForwardStartup localPort process)
      (runAfterAuthorityBackupForwardStartup localPort)
  runAfterAuthorityBackupForwardStartup localPort = do
    ready <- waitUntilStartupProbe AuthorityBackupRuntime localPort 1
    case ready of
      Left detail ->
        pure (Left (LocalAuthorityBackupLivenessFailed detail))
      Right () ->
        case authorityBackupClient localPort of
          Left err -> pure (Left (LocalAuthorityBackupClientInvalid err))
          Right client -> Right <$> action client

continueAuthorityBackupForwardAfterStartupWith
  :: IO (Either LocalAuthorityBackupError ())
  -> IO (Either LocalAuthorityBackupError value)
  -> IO (Either LocalAuthorityBackupError value)
continueAuthorityBackupForwardAfterStartupWith awaitStartup continue = do
  startup <- awaitStartup
  case startup of
    Left err -> pure (Left err)
    Right () -> continue

-- | Retry the complete disposable Authority Backup port-forward lifecycle.
-- Only listener liveness is pending: setup/client failures are terminal, and
-- the user action is inside a successful attempt so its result is never
-- repeated. 'bracket' retires the current child before the inter-attempt delay.
retryAuthorityBackupForwardWith
  :: Int
  -> IO ()
  -> IO (Either LocalAuthorityBackupError process)
  -> (Either LocalAuthorityBackupError process -> IO ())
  -> (process -> IO (Either LocalAuthorityBackupError value))
  -> IO (Either LocalAuthorityBackupError value)
retryAuthorityBackupForwardWith attemptBudget delay acquire release use =
  go (max 1 attemptBudget)
 where
  go remaining = do
    result <-
      bracket acquire release runStarted
    case result of
      Left err@(LocalAuthorityBackupLivenessFailed _)
        | remaining > 1 -> delay >> go (remaining - 1)
        | otherwise -> pure (Left err)
      _ -> pure result
  runStarted started = case started of
    Left err -> pure (Left err)
    Right process -> use process

withLocalAuthorityBackupAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'AuthorityBackupRuntime -> IO value)
  -> IO (Either LocalAuthorityBackupError value)
withLocalAuthorityBackupAuthenticatedTransport bounds providers action =
  withLocalAuthorityBackupClient
    (action . mkAuthenticatedClientTransport bounds providers)

data LocalTlsRetentionError
  = LocalTlsRetentionKubeconfigFailed !String
  | LocalTlsRetentionPortReservationFailed !String
  | LocalTlsRetentionProcessStartFailed !String
  | LocalTlsRetentionReadinessFailed !String
  | LocalTlsRetentionClientInvalid !ControlPlaneClientError
  deriving stock (Eq, Show)

renderLocalTlsRetentionError :: LocalTlsRetentionError -> String
renderLocalTlsRetentionError err = case err of
  LocalTlsRetentionKubeconfigFailed detail ->
    "resolve home TLS Retention kubeconfig: " ++ detail
  LocalTlsRetentionPortReservationFailed detail ->
    "reserve TLS Retention loopback port: " ++ detail
  LocalTlsRetentionProcessStartFailed detail ->
    "start TLS Retention Service port-forward: " ++ detail
  LocalTlsRetentionReadinessFailed detail ->
    "TLS Retention Service is not ready: " ++ detail
  LocalTlsRetentionClientInvalid detail ->
    "construct TLS Retention client: " ++ show detail

withLocalTlsRetentionClient
  :: (ControlPlaneClient 'TlsRetentionRuntime -> IO value)
  -> IO (Either LocalTlsRetentionError value)
withLocalTlsRetentionClient action = do
  kubeconfigResult <- resolveLocalKubeconfig
  case kubeconfigResult of
    Left detail -> pure (Left (LocalTlsRetentionKubeconfigFailed detail))
    Right kubeconfig -> do
      portResult <- reserveLoopbackPort
      case portResult of
        Left detail -> pure (Left (LocalTlsRetentionPortReservationFailed detail))
        Right localPort -> do
          environment <- homeKubectlEnvironment kubeconfig
          bracket
            (startTlsRetentionForward environment localPort)
            cleanupTlsRetentionForward
            (runWithTlsRetentionForward localPort)
 where
  runWithTlsRetentionForward _ (Left err) = pure (Left err)
  runWithTlsRetentionForward localPort (Right _) = do
    ready <- waitUntilStartupProbe TlsRetentionRuntime localPort readinessAttempts
    case ready of
      Left detail -> pure (Left (LocalTlsRetentionReadinessFailed detail))
      Right () -> case tlsRetentionClient localPort of
        Left err -> pure (Left (LocalTlsRetentionClientInvalid err))
        Right client -> Right <$> action client

withLocalTlsRetentionAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'TlsRetentionRuntime -> IO value)
  -> IO (Either LocalTlsRetentionError value)
withLocalTlsRetentionAuthenticatedTransport bounds providers action =
  withLocalTlsRetentionClient
    (action . mkAuthenticatedClientTransport bounds providers)

lifecycleAuthorityNamespace :: String
lifecycleAuthorityNamespace = "lifecycle-authority"

lifecycleAuthorityService :: String
lifecycleAuthorityService = "lifecycle-authority"

lifecycleAuthorityForwardTarget :: String
lifecycleAuthorityForwardTarget = "service/" ++ lifecycleAuthorityService

-- | Sprint 3.35: all five per-role ports are the one compiled
-- 'controlPlaneListenPort'. They stay separately named because each is read
-- beside its own namespace/service pair, but they no longer restate the value:
-- a per-role port is not representable in @runControlPlaneServer@, which binds
-- without consulting the role it is given.
lifecycleAuthorityRemotePort :: Int
lifecycleAuthorityRemotePort = controlPlaneListenPort

targetSecretAgentNamespace :: String
targetSecretAgentNamespace = "target-secret-agent"

targetSecretAgentService :: String
targetSecretAgentService = "target-secret-agent"

targetSecretAgentForwardTarget :: String
targetSecretAgentForwardTarget = "service/" ++ targetSecretAgentService

targetSecretAgentRemotePort :: Int
targetSecretAgentRemotePort = controlPlaneListenPort

providerWorkerNamespace :: String
providerWorkerNamespace = "provider-worker"

providerWorkerService :: String
providerWorkerService = "provider-worker"

providerWorkerForwardTarget :: String
providerWorkerForwardTarget = "service/" ++ providerWorkerService

providerWorkerRemotePort :: Int
providerWorkerRemotePort = controlPlaneListenPort

authorityBackupNamespace :: String
authorityBackupNamespace = "authority-backup"

authorityBackupDeployment :: String
authorityBackupDeployment = "authority-backup"

-- Genesis must reach the live process before credential-backed readiness can
-- publish it as a Service endpoint. The chart's Recreate strategy makes the
-- Deployment selector single-generation during this pre-readiness interval.
authorityBackupForwardTarget :: String
authorityBackupForwardTarget = "deployment/" ++ authorityBackupDeployment

authorityBackupRemotePort :: Int
authorityBackupRemotePort = controlPlaneListenPort

tlsRetentionNamespace :: String
tlsRetentionNamespace = "tls-retention"

tlsRetentionService :: String
tlsRetentionService = "tls-retention"

tlsRetentionForwardTarget :: String
tlsRetentionForwardTarget = "service/" ++ tlsRetentionService

tlsRetentionRemotePort :: Int
tlsRetentionRemotePort = controlPlaneListenPort

readinessAttempts :: Int
readinessAttempts = 240

startForward
  :: [(String, String)]
  -> Int
  -> IO (Either LocalLifecycleAuthorityError BackgroundProcess)
startForward environment localPort = do
  started <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , lifecycleAuthorityNamespace
            , "port-forward"
            , lifecycleAuthorityForwardTarget
            , show localPort ++ ":" ++ show lifecycleAuthorityRemotePort
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case started of
    Left err ->
      Left (LocalLifecycleAuthorityProcessStartFailed (Text.unpack (errorMsg err)))
    Right process -> Right process

cleanupForward
  :: Either LocalLifecycleAuthorityError BackgroundProcess
  -> IO ()
cleanupForward result = case result of
  Left _ -> pure ()
  Right process -> stopBackgroundProcess process

startTargetForward
  :: [(String, String)]
  -> Int
  -> IO (Either LocalTargetSecretAgentError BackgroundProcess)
startTargetForward environment localPort = do
  started <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , targetSecretAgentNamespace
            , "port-forward"
            , targetSecretAgentForwardTarget
            , show localPort ++ ":" ++ show targetSecretAgentRemotePort
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case started of
    Left err ->
      Left (LocalTargetSecretAgentProcessStartFailed (Text.unpack (errorMsg err)))
    Right process -> Right process

cleanupTargetForward
  :: Either LocalTargetSecretAgentError BackgroundProcess
  -> IO ()
cleanupTargetForward result = case result of
  Left _ -> pure ()
  Right process -> stopBackgroundProcess process

startProviderForward
  :: [(String, String)]
  -> Int
  -> IO (Either LocalProviderWorkerError BackgroundProcess)
startProviderForward environment localPort = do
  started <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , providerWorkerNamespace
            , "port-forward"
            , providerWorkerForwardTarget
            , show localPort ++ ":" ++ show providerWorkerRemotePort
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case started of
    Left err ->
      Left (LocalProviderWorkerProcessStartFailed (Text.unpack (errorMsg err)))
    Right process -> Right process

cleanupProviderForward
  :: Either LocalProviderWorkerError BackgroundProcess
  -> IO ()
cleanupProviderForward result = case result of
  Left _ -> pure ()
  Right process -> stopBackgroundProcess process

startAuthorityBackupForward
  :: [(String, String)]
  -> Int
  -> IO (Either LocalAuthorityBackupError BackgroundProcess)
startAuthorityBackupForward environment localPort = do
  started <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , authorityBackupNamespace
            , "port-forward"
            , authorityBackupForwardTarget
            , show localPort ++ ":" ++ show authorityBackupRemotePort
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case started of
    Left err ->
      Left (LocalAuthorityBackupProcessStartFailed (Text.unpack (errorMsg err)))
    Right process -> Right process

cleanupAuthorityBackupForward
  :: Either LocalAuthorityBackupError BackgroundProcess
  -> IO ()
cleanupAuthorityBackupForward result = case result of
  Left _ -> pure ()
  Right process -> stopBackgroundProcess process

waitForAuthorityBackupForwardStartup
  :: Int
  -> BackgroundProcess
  -> IO (Either LocalAuthorityBackupError ())
waitForAuthorityBackupForwardStartup localPort process =
  case backgroundStdoutHandle process of
    Nothing ->
      pure
        ( classifyAuthorityBackupForwardStartup
            localPort
            AuthorityBackupForwardStartupReadFailed
        )
    Just stdoutHandle -> do
      observed <-
        timeout
          authorityBackupForwardStartupTimeoutMicros
          (try (hGetLine stdoutHandle) :: IO (Either IOException String))
      pure
        ( classifyAuthorityBackupForwardStartup
            localPort
            ( case observed of
                Nothing -> AuthorityBackupForwardStartupTimedOut
                Just (Left _) -> AuthorityBackupForwardStartupReadFailed
                Just (Right line) -> AuthorityBackupForwardStartupLine line
            )
        )

classifyAuthorityBackupForwardStartup
  :: Int
  -> AuthorityBackupForwardStartupObservation
  -> Either LocalAuthorityBackupError ()
classifyAuthorityBackupForwardStartup localPort observation =
  case observation of
    AuthorityBackupForwardStartupTimedOut -> refused "startup acknowledgement timed out"
    AuthorityBackupForwardStartupReadFailed -> refused "startup acknowledgement unavailable"
    AuthorityBackupForwardStartupLine line
      | line `elem` expectedLines -> Right ()
      | otherwise -> refused "startup acknowledgement did not match the compiled loopback mapping"
 where
  refused = Left . LocalAuthorityBackupLivenessFailed
  expectedLines =
    [ "Forwarding from 127.0.0.1:" ++ show localPort ++ mappingSuffix
    , "Forwarding from [::1]:" ++ show localPort ++ mappingSuffix
    ]
  mappingSuffix = " -> " ++ show authorityBackupRemotePort

authorityBackupForwardStartupTimeoutMicros :: Int
authorityBackupForwardStartupTimeoutMicros = 1000000

startTlsRetentionForward
  :: [(String, String)]
  -> Int
  -> IO (Either LocalTlsRetentionError BackgroundProcess)
startTlsRetentionForward environment localPort = do
  started <-
    startBackgroundProcess
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "--namespace"
            , tlsRetentionNamespace
            , "port-forward"
            , tlsRetentionForwardTarget
            , show localPort ++ ":" ++ show tlsRetentionRemotePort
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case started of
    Left err ->
      Left (LocalTlsRetentionProcessStartFailed (Text.unpack (errorMsg err)))
    Right process -> Right process

cleanupTlsRetentionForward
  :: Either LocalTlsRetentionError BackgroundProcess
  -> IO ()
cleanupTlsRetentionForward result = case result of
  Left _ -> pure ()
  Right process -> stopBackgroundProcess process

waitUntilStartupProbe :: RuntimeRole -> Int -> Int -> IO (Either String ())
waitUntilStartupProbe role localPort remaining = do
  result <-
    httpRequestNoBody
      readinessHttpConfig
      "GET"
      []
      (loopbackEndpoint localPort ++ localClientStartupProbePath role)
  case result of
    Right () -> pure (Right ())
    Left err
      | remaining <= 1 -> pure (Left (renderHttpError err))
      | otherwise -> do
          threadDelay 250000
          waitUntilStartupProbe role localPort (remaining - 1)

-- | Authority Backup is contacted during genesis before its S3 credential
-- exists, so that one local client waits only for listener liveness. Every
-- other role retains capability-backed readiness as its startup barrier.
localClientStartupProbePath :: RuntimeRole -> String
localClientStartupProbePath role = case role of
  BootstrapBroker -> "/readyz"
  GatewayRuntime -> "/readyz"
  LifecycleAuthorityRuntime -> "/readyz"
  ProviderWorkerRuntime -> "/readyz"
  AuthorityBackupRuntime -> "/healthz"
  TlsRetentionRuntime -> "/readyz"
  TargetSecretAgentRuntime -> "/readyz"

readinessHttpConfig :: HttpConfig
readinessHttpConfig =
  defaultHttpConfig {httpRequestTimeoutMicros = 1000000}

lifecycleAuthorityClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'LifecycleAuthorityRuntime)
lifecycleAuthorityClient localPort = do
  endpoint <- mkLifecycleAuthorityEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    lifecycleAuthorityHttpConfig
    (100 * 1024 * 1024)
    endpoint

lifecycleAuthorityHttpConfig :: HttpConfig
lifecycleAuthorityHttpConfig =
  defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}

lifecycleAuthorityRetainedDeliveryHttpConfig :: HttpConfig
lifecycleAuthorityRetainedDeliveryHttpConfig =
  defaultHttpConfig
    { httpRequestTimeoutMicros =
        RetainedMaterialDeliveryBudget.retainedMaterialDeliveryResponseTimeoutMicros
    }

lifecycleAuthorityRetainedDeliveryClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'LifecycleAuthorityRuntime)
lifecycleAuthorityRetainedDeliveryClient localPort = do
  endpoint <- mkLifecycleAuthorityEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    lifecycleAuthorityRetainedDeliveryHttpConfig
    (100 * 1024 * 1024)
    endpoint

lifecycleAuthorityTlsWorkflowHttpConfig :: HttpConfig
lifecycleAuthorityTlsWorkflowHttpConfig =
  defaultHttpConfig
    { httpRequestTimeoutMicros =
        TlsRetentionWorkflowBudget.tlsRetentionWorkflowResponseTimeoutMicros
    }

lifecycleAuthorityTlsWorkflowClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'LifecycleAuthorityRuntime)
lifecycleAuthorityTlsWorkflowClient localPort = do
  endpoint <- mkLifecycleAuthorityEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    lifecycleAuthorityTlsWorkflowHttpConfig
    (100 * 1024 * 1024)
    endpoint

targetSecretAgentClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'TargetSecretAgentRuntime)
targetSecretAgentClient localPort = do
  endpoint <- mkTargetSecretAgentEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
    (4 * 1024 * 1024)
    endpoint

providerWorkerClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'ProviderWorkerRuntime)
providerWorkerClient localPort = do
  endpoint <- mkProviderWorkerEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
    (4 * 1024 * 1024)
    endpoint

authorityBackupClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'AuthorityBackupRuntime)
authorityBackupClient localPort = do
  endpoint <- mkAuthorityBackupEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
    (100 * 1024 * 1024)
    endpoint

tlsRetentionClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'TlsRetentionRuntime)
tlsRetentionClient localPort = do
  endpoint <- mkTlsRetentionEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}
    (4 * 1024 * 1024)
    endpoint

loopbackEndpoint :: Int -> String
loopbackEndpoint port = "http://127.0.0.1:" ++ show port

homeKubectlEnvironment :: FilePath -> IO [(String, String)]
homeKubectlEnvironment kubeconfig = do
  environment <- getEnvironment
  pure
    ( ("KUBECONFIG", kubeconfig)
        : filter ((/= "KUBECONFIG") . fst) environment
    )

reserveLoopbackPort :: IO (Either String Int)
reserveLoopbackPort = do
  attempted <-
    try
      ( withSocketsDo $
          bracket
            (socket AF_INET Stream defaultProtocol)
            close
            ( \reserved -> do
                setSocketOption reserved ReuseAddr 1
                bind reserved (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
                address <- getSocketName reserved
                case address of
                  SockAddrInet port _ -> pure (fromIntegral port)
                  _ -> ioError (userError "reserved socket was not IPv4")
            )
      )
      :: IO (Either IOException Int)
  pure (either (Left . displayException) Right attempted)
