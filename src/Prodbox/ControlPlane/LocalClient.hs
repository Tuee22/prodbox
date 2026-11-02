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
  , withOperationLifecycleAuthorityAuthenticatedTransport
  , OperationLifecycleAuthorityChannel
  , withOperationLifecycleAuthorityChannel
  , operationLifecycleAuthorityAuthenticatedTransport
  , requestOperationLifecycleAuthorityOwnBindingHint
  , requestOperationLifecycleAuthorityBootstrapRegistry
  , verifyOperationLifecycleAuthorityChannelBeforeEffect
  , withLocalLifecycleAuthorityProviderAuthenticatedTransport
  , withLocalLifecycleAuthorityRetainedDeliveryAuthenticatedTransport
  , withLocalLifecycleAuthorityTlsWorkflowAuthenticatedTransport
  , lifecycleAuthorityHttpConfig
  , lifecycleAuthorityProviderHttpConfig
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
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception
  ( IOException
  , bracket
  , displayException
  , evaluate
  , try
  )
import Control.Monad (join)
import Data.Bifunctor (first)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
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
import Prodbox.Capacity.ControlPlaneReplayBudget qualified as ReplayBudget
import Prodbox.Capacity.ProviderWorkerBudget qualified as ProviderWorkerBudget
import Prodbox.Capacity.RetainedMaterialDeliveryBudget qualified as RetainedMaterialDeliveryBudget
import Prodbox.Capacity.TlsRetentionWorkflowBudget qualified as TlsRetentionWorkflowBudget
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneClientError
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleMigrationApplyRoute)
  , callControlPlane
  , controlPlaneClientWithTransport
  , mkAuthorityBackupEndpoint
  , mkLifecycleAuthorityEndpoint
  , mkProviderWorkerEndpoint
  , mkTargetSecretAgentEndpoint
  , mkTlsRetentionEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.HomeEndpoint qualified as Home
import Prodbox.ControlPlane.OperationUse qualified as Uses
import Prodbox.ControlPlane.RegisteredRpcSigning (NativeRpcSigningInterpreter)
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , mkRequestSigningCapability
  , requestSigningCapabilityGeneration
  , requestSigningCapabilityPrincipal
  , requestSigningCapabilityPublicKeyBytes
  , signCanonicalBytesWithRequestCapability
  )
import Prodbox.ControlPlane.RpcAdmissionBirth (RpcBirthServingMode)
import Prodbox.ControlPlane.RpcAdmissionBirthBootstrap
  ( RpcBirthBootstrapError
  , observeRpcBirthBootstrapRegistry
  )
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint (rpcBirthRegistryResponseMaximumBytes)
import Prodbox.ControlPlane.RpcAdmissionBirthExecution (RpcBirthRegistryObservation)
import Prodbox.ControlPlane.RpcOwnBindingHint
  ( RpcOwnBindingHint
  , RpcOwnBindingHintError
  , RpcOwnBindingQuery
  , decodeRpcOwnBindingHint
  , encodeRpcOwnBindingQuery
  )
import Prodbox.Error (errorMsg)
import Prodbox.Http.Client
  ( HttpBoundedError (..)
  , HttpConfig (..)
  , HttpError (HttpConnectionFailure, HttpTimeout)
  , defaultHttpConfig
  , httpRequestNoBody
  , httpRequestRawBounded
  , renderHttpError
  )
import Prodbox.Infra.MinioBackend (resolveLocalKubeconfig)
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EmbeddedHomeKubeconfig
  , forbiddenKubectlEnvironmentKey
  , writeEmbeddedHomeKubeconfig
  )
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Subprocess
  ( BackgroundProcess (..)
  , OperationSubprocessError
  , OperationSubprocesses
  , OperationTransport
  , Subprocess (..)
  , observeOperationTransportStartup
  , operationSubprocessRuntimeDirectory
  , operationTransportWorkEnd
  , startBackgroundProcess
  , stopBackgroundProcess
  , verifyOperationSubprocessesBeforeEffect
  , verifyOperationTransportBeforeEffect
  , withOperationTransportStartup
  )
import Prodbox.Subprocess.StartupLine qualified as Startup
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.IO (hGetLine)
import System.IO.Temp (createTempDirectory)
import System.Timeout (timeout)

data LocalLifecycleAuthorityError
  = LocalLifecycleAuthorityOperationFailed !OperationSubprocessError
  | LocalLifecycleAuthorityOperationDeadline
  | LocalLifecycleAuthorityWorkspaceFailed
  | LocalLifecycleAuthorityKubeconfigFailed !String
  | LocalLifecycleAuthorityPortReservationFailed !String
  | LocalLifecycleAuthorityProcessStartFailed !String
  | LocalLifecycleAuthorityReadinessFailed !String
  | LocalLifecycleAuthorityClientInvalid !ControlPlaneClientError
  | LocalLifecycleAuthorityChannelClosed
  | LocalLifecycleAuthorityRequestRefused !ControlPlaneClientError
  | LocalLifecycleAuthorityHintRefused !RpcOwnBindingHintError
  | LocalLifecycleAuthorityHintHttpStatus !Int
  | LocalLifecycleAuthorityBootstrapRefused !RpcBirthBootstrapError
  deriving stock (Eq, Show)

renderLocalLifecycleAuthorityError :: LocalLifecycleAuthorityError -> String
renderLocalLifecycleAuthorityError err = case err of
  LocalLifecycleAuthorityOperationFailed cause -> "owned Lifecycle Authority transport: " ++ show cause
  LocalLifecycleAuthorityOperationDeadline -> "owned Lifecycle Authority transport reached its original work deadline"
  LocalLifecycleAuthorityWorkspaceFailed -> "prepare owned Lifecycle Authority kubeconfig workspace"
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
  LocalLifecycleAuthorityChannelClosed -> "owned Lifecycle Authority channel is closed"
  LocalLifecycleAuthorityRequestRefused cause -> "owned Lifecycle Authority request: " ++ show cause
  LocalLifecycleAuthorityHintRefused cause -> "owned Lifecycle Authority hint: " ++ show cause
  LocalLifecycleAuthorityHintHttpStatus status -> "owned Lifecycle Authority hint HTTP status: " ++ show status
  LocalLifecycleAuthorityBootstrapRefused cause -> "owned Lifecycle Authority bootstrap: " ++ show cause

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

-- The operation owns both this persistent child and all concurrent command work.
-- Only the canonical retained-home Authority mapping is representable here.
withOperationLifecycleAuthorityAuthenticatedTransport
  :: OperationSubprocesses
  -> EmbeddedHomeKubeconfig
  -> [(String, String)]
  -> AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withOperationLifecycleAuthorityAuthenticatedTransport processes config environment bounds providers action =
  withOperationLifecycleAuthorityChannelUsingMaximum
    ReplayBudget.authorityMetadataResponseMaximumBytes
    processes
    config
    environment
    (action . operationLifecycleAuthorityAuthenticatedTransport bounds providers)

-- The client cannot be selected or extracted by callers. Release joins every
-- bounded use before closing the lease; escaped uses subsequently refuse.
-- Neither a channel nor its local lifetime grants Authority admission.
data OperationLifecycleAuthorityChannel
  = OperationLifecycleAuthorityChannel
      !OperationAuthorityChannelScope
      !(ControlPlaneClient 'LifecycleAuthorityRuntime)
      !(ControlPlaneClient 'LifecycleAuthorityRuntime)

data OperationAuthorityChannelScope
  = OperationAuthorityChannelScope !OperationTransport !Uses.OperationUses

withOperationLifecycleAuthorityChannel
  :: OperationSubprocesses
  -> EmbeddedHomeKubeconfig
  -> [(String, String)]
  -> (OperationLifecycleAuthorityChannel -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withOperationLifecycleAuthorityChannel =
  withOperationLifecycleAuthorityChannelUsingMaximum rpcBirthRegistryResponseMaximumBytes

operationLifecycleAuthorityAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> OperationLifecycleAuthorityChannel
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
operationLifecycleAuthorityAuthenticatedTransport bounds providers (OperationLifecycleAuthorityChannel scope client _) =
  mkAuthenticatedClientTransport bounds guarded client
 where
  guarded =
    AuthenticatedClientProviders
      { provideAuthenticatedClientSigner = do
          provided <- guardChannelProvider scope (provideAuthenticatedClientSigner providers)
          pure $ do
            signer <- provided
            first (const "owned Authority channel signer invalid") $
              mkRequestSigningCapability
                (requestSigningCapabilityPrincipal signer)
                (requestSigningCapabilityGeneration signer)
                (requestSigningCapabilityPublicKeyBytes signer)
                ( \bytes ->
                    guardChannelProvider
                      scope
                      (first (Text.pack . show) <$> signCanonicalBytesWithRequestCapability signer bytes)
                )
      , provideAuthenticatedClientScope =
          guardChannelProvider scope (provideAuthenticatedClientScope providers)
      , provideAuthenticatedClientEpoch =
          guardChannelProvider scope (provideAuthenticatedClientEpoch providers)
      , provideAuthenticatedClientDeadline =
          guardChannelProvider scope (provideAuthenticatedClientDeadline providers)
      , provideAuthenticatedClientNonce =
          guardChannelProvider scope (provideAuthenticatedClientNonce providers)
      }

guardChannelProvider
  :: OperationAuthorityChannelScope
  -> IO (Either Text.Text value)
  -> IO (Either Text.Text value)
guardChannelProvider scope action =
  either (Left . Text.pack . renderLocalLifecycleAuthorityError) id
    <$> withOperationAuthorityChannelUse scope action

verifyOperationLifecycleAuthorityChannelBeforeEffect
  :: OperationLifecycleAuthorityChannel -> IO (Either LocalLifecycleAuthorityError ())
verifyOperationLifecycleAuthorityChannelBeforeEffect (OperationLifecycleAuthorityChannel scope _ _) =
  withOperationAuthorityChannelUse scope (pure ())

requestOperationLifecycleAuthorityOwnBindingHint
  :: OperationLifecycleAuthorityChannel
  -> RpcOwnBindingQuery
  -> IO (Either LocalLifecycleAuthorityError RpcOwnBindingHint)
requestOperationLifecycleAuthorityOwnBindingHint (OperationLifecycleAuthorityChannel scope client _) query =
  fmap join $ withOperationAuthorityChannelUse scope $ do
    response <- callControlPlane client LifecycleMigrationApplyRoute (encodeRpcOwnBindingQuery query)
    decoded <- evaluate $ case response of
      Left cause -> Left (LocalLifecycleAuthorityRequestRefused cause)
      Right (ControlPlaneResponse status body)
        | status /= 200 -> Left (LocalLifecycleAuthorityHintHttpStatus status)
        | otherwise ->
            either (Left . LocalLifecycleAuthorityHintRefused) Right (decodeRpcOwnBindingHint query body)
    case decoded of
      Left cause -> cause `seq` pure (Left cause)
      Right hint -> hint `seq` pure (Right hint)

-- The complete fixed program, including native origin/public/signing effects,
-- holds the same joined borrow. Only registry metadata can leave this method.
requestOperationLifecycleAuthorityBootstrapRegistry
  :: OperationLifecycleAuthorityChannel
  -> NativeRpcSigningInterpreter IO
  -> IO (Either Text.Text AuthorityTime)
  -> IO (Either Text.Text RequestNonce)
  -> AuthorityScope
  -> RpcBirthServingMode
  -> AuthorityTime
  -> AuthenticatedTransportBounds
  -> IO (Either LocalLifecycleAuthorityError RpcBirthRegistryObservation)
requestOperationLifecycleAuthorityBootstrapRegistry (OperationLifecycleAuthorityChannel scope _ client) native readTime nonce authority mode deadline bounds = do
  result <-
    withOperationAuthorityChannelUse scope $
      observeRpcBirthBootstrapRegistry native readTime nonce authority mode deadline bounds client
  pure (result >>= first LocalLifecycleAuthorityBootstrapRefused)

-- The shared owner counts nested uses without holding a mutex over effects.
-- This channel selects its exact persistent transport as the observed source.
withOperationAuthorityChannelUse
  :: OperationAuthorityChannelScope
  -> IO value
  -> IO (Either LocalLifecycleAuthorityError value)
withOperationAuthorityChannelUse (OperationAuthorityChannelScope _ uses) action =
  first classify <$> Uses.withOperationUse uses action
 where
  classify cause = case cause of
    Uses.OperationUseClosed -> LocalLifecycleAuthorityChannelClosed
    Uses.OperationUseDeadlineReached -> LocalLifecycleAuthorityOperationDeadline
    Uses.OperationUseProcessRefused failure -> LocalLifecycleAuthorityOperationFailed failure

withOperationLifecycleAuthorityChannelUsingMaximum
  :: Int
  -> OperationSubprocesses
  -> EmbeddedHomeKubeconfig
  -> [(String, String)]
  -> (OperationLifecycleAuthorityChannel -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withOperationLifecycleAuthorityChannelUsingMaximum maximumBytes processes config environment action = do
  admitted <- verifyOperationSubprocessesBeforeEffect processes
  case admitted of
    Left cause -> pure (Left (LocalLifecycleAuthorityOperationFailed cause))
    Right () -> do
      attempted <- tryOperationClientWorkspace $ do
        directory <-
          createTempDirectory (operationSubprocessRuntimeDirectory processes) "authority-forward-"
        use directory
      pure (either (const (Left LocalLifecycleAuthorityWorkspaceFailed)) id attempted)
 where
  use directory = do
    written <- writeEmbeddedHomeKubeconfig directory config
    case written of
      Left _ -> pure (Left LocalLifecycleAuthorityWorkspaceFailed)
      Right kubeconfig -> do
        port <- reserveLoopbackPort
        case port of
          Left detail -> pure (Left (LocalLifecycleAuthorityPortReservationFailed detail))
          Right localPort -> do
            let childEnvironment =
                  [ ("HOME", directory)
                  , ("XDG_CACHE_HOME", directory </> "cache")
                  , ("XDG_CONFIG_HOME", directory </> "config")
                  , ("XDG_DATA_HOME", directory </> "data")
                  ]
                    ++ filter (not . privateEnvironmentKey . fst) environment
                spec =
                  Subprocess
                    { subprocessPath = "kubectl"
                    , subprocessArguments =
                        [ "--kubeconfig"
                        , kubeconfig
                        , "--cache-dir"
                        , directory </> "cache"
                        , "--namespace"
                        , lifecycleAuthorityNamespace
                        , "port-forward"
                        , lifecycleAuthorityForwardTarget
                        , show localPort ++ ":" ++ show lifecycleAuthorityRemotePort
                        , "--address"
                        , "127.0.0.1"
                        ]
                    , subprocessEnvironment = Just childEnvironment
                    , subprocessWorkingDirectory = Just directory
                    }
            case Startup.mkStartupLineExpectation
              (map Bytes.pack (Home.homeControlPlaneForwardStartupLines Home.HomeLifecycleAuthority localPort)) of
              Left _ -> pure (Left (LocalLifecycleAuthorityReadinessFailed "startup mapping invalid"))
              Right expected -> do
                forwarded <- withOperationTransportStartup processes spec expected $ \lease -> do
                  ready <- waitOperationAuthorityReady lease localPort
                  case ready of
                    Left cause -> pure (Left cause)
                    Right () -> Uses.withOperationTransportUses lease $ \uses -> do
                      httpGate <- newMVar ()
                      let scope = OperationAuthorityChannelScope lease uses
                          clients =
                            (,)
                              <$> operationAuthorityChannelClient (min 65536 maximumBytes) scope httpGate localPort
                              <*> operationAuthorityChannelClient maximumBytes scope httpGate localPort
                      case clients of
                        Left cause -> pure (Left (LocalLifecycleAuthorityClientInvalid cause))
                        Right (ordinary, registry) ->
                          Right <$> action (OperationLifecycleAuthorityChannel scope ordinary registry)
                pure (either (Left . LocalLifecycleAuthorityOperationFailed) id forwarded)
  privateEnvironmentKey key =
    forbiddenKubectlEnvironmentKey key
      || key `elem` ["HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]

operationAuthorityChannelClient
  :: Int
  -> OperationAuthorityChannelScope
  -> MVar ()
  -> Int
  -> Either ControlPlaneClientError (ControlPlaneClient 'LifecycleAuthorityRuntime)
operationAuthorityChannelClient maximumBytes scope@(OperationAuthorityChannelScope lease _) httpGate localPort = do
  endpoint <- mkLifecycleAuthorityEndpoint (Text.pack (loopbackEndpoint localPort))
  controlPlaneClientWithTransport maximumBytes endpoint $ \method headers url body ->
    fmap (either (const refused) id) $
      withOperationAuthorityChannelUse scope $
        withMVar httpGate $ \() -> do
          now <- getMonotonicTimeNSec
          let ending = operationTransportWorkEnd lease
          if now >= ending || ending - now < 1000
            then pure expired
            else do
              let micros = fromInteger (min (toInteger (maxBound :: Int)) (toInteger ((ending - now) `div` 1000)))
                  config = HttpConfig (min micros (httpRequestTimeoutMicros lifecycleAuthorityHttpConfig))
              httpRequestRawBounded config maximumBytes method headers url (Just (Lazy.fromStrict body))
 where
  refused = Left (HttpBoundedTransport (HttpConnectionFailure "owned Authority channel refused"))
  expired = Left (HttpBoundedTransport (HttpTimeout "owned Authority channel original work deadline"))

tryOperationClientWorkspace :: IO value -> IO (Either IOException value)
tryOperationClientWorkspace = try

waitOperationAuthorityReady
  :: OperationTransport -> Int -> IO (Either LocalLifecycleAuthorityError ())
waitOperationAuthorityReady lease localPort = acknowledge
 where
  acknowledge = do
    observed <- observeOperationTransportStartup lease
    case observed of
      Left cause -> pure (Left (LocalLifecycleAuthorityOperationFailed cause))
      Right Startup.StartupLineAccepted -> loop
      Right Startup.StartupLinePending -> do
        now <- getMonotonicTimeNSec
        if now >= ending || ending - now < 1000
          then pure (Left LocalLifecycleAuthorityOperationDeadline)
          else do
            threadDelay (fromInteger (min 25000 ((toInteger ending - toInteger now) `div` 1000)))
            acknowledge
      Right Startup.StartupLineRejected -> refused "startup acknowledgement does not match the compiled loopback mapping"
      Right Startup.StartupLineIncomplete -> refused "startup acknowledgement ended before a complete matching line"
      Right Startup.StartupLineReadFailed -> refused "startup acknowledgement unavailable"
      Right Startup.StartupLineExceeded -> refused "startup stdout exceeded its bound"
      Right Startup.StartupLineUnconfigured -> refused "startup acknowledgement was not configured"
  refused = pure . Left . LocalLifecycleAuthorityReadinessFailed
  ending = operationTransportWorkEnd lease
  endpoint = loopbackEndpoint localPort ++ localClientStartupProbePath LifecycleAuthorityRuntime
  loop = do
    observed <- verifyOperationTransportBeforeEffect lease
    case observed of
      Left cause -> pure (Left (LocalLifecycleAuthorityOperationFailed cause))
      Right () -> do
        now <- getMonotonicTimeNSec
        if now >= ending || ending - now < 1000
          then pure (Left LocalLifecycleAuthorityOperationDeadline)
          else do
            let allowance = fromInteger (min 1000000 (toInteger ((ending - now) `div` 1000)))
            response <-
              timeout allowance $
                httpRequestRawBounded (HttpConfig allowance) 4096 "GET" [] endpoint Nothing
            after <- getMonotonicTimeNSec
            if after >= ending
              then pure (Left LocalLifecycleAuthorityOperationDeadline)
              else case response of
                Just (Right (status, _)) | status >= 200 && status < 300 -> do
                  closing <- verifyOperationTransportBeforeEffect lease
                  pure (either (Left . LocalLifecycleAuthorityOperationFailed) (const (Right ())) closing)
                Just (Left (HttpBoundedResponseTooLarge _ _)) ->
                  pure (Left (LocalLifecycleAuthorityReadinessFailed "startup response exceeds its 4096-byte bound"))
                Just (Left (HttpBoundedResponseHeadersTooLarge {})) ->
                  pure
                    (Left (LocalLifecycleAuthorityReadinessFailed "startup response exceeds its retained-header bound"))
                _ -> do
                  threadDelay (fromInteger (min 250000 ((toInteger ending - toInteger after) `div` 1000)))
                  loop

-- | Open the same exact Authority endpoint with only the response budget of
-- the Provider execution route widened to contain its admitted child schedule.
withLocalLifecycleAuthorityProviderAuthenticatedTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (Either LocalLifecycleAuthorityError value)
withLocalLifecycleAuthorityProviderAuthenticatedTransport bounds providers action =
  withLocalLifecycleAuthorityClientUsing
    lifecycleAuthorityProviderClient
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
lifecycleAuthorityNamespace = Home.homeControlPlaneNamespace Home.HomeLifecycleAuthority

lifecycleAuthorityForwardTarget :: String
lifecycleAuthorityForwardTarget = Home.homeControlPlaneForwardTarget Home.HomeLifecycleAuthority

lifecycleAuthorityRemotePort :: Int
lifecycleAuthorityRemotePort = Home.homeControlPlaneRemotePort Home.HomeLifecycleAuthority

targetSecretAgentNamespace :: String
targetSecretAgentNamespace = Home.homeControlPlaneNamespace Home.HomeTargetSecretAgent

targetSecretAgentForwardTarget :: String
targetSecretAgentForwardTarget = Home.homeControlPlaneForwardTarget Home.HomeTargetSecretAgent

targetSecretAgentRemotePort :: Int
targetSecretAgentRemotePort = Home.homeControlPlaneRemotePort Home.HomeTargetSecretAgent

providerWorkerNamespace :: String
providerWorkerNamespace = Home.homeControlPlaneNamespace Home.HomeProviderWorker

providerWorkerForwardTarget :: String
providerWorkerForwardTarget = Home.homeControlPlaneForwardTarget Home.HomeProviderWorker

providerWorkerRemotePort :: Int
providerWorkerRemotePort = Home.homeControlPlaneRemotePort Home.HomeProviderWorker

authorityBackupNamespace :: String
authorityBackupNamespace = Home.homeControlPlaneNamespace Home.HomeAuthorityBackup

authorityBackupForwardTarget :: String
authorityBackupForwardTarget = Home.homeControlPlaneForwardTarget Home.HomeAuthorityBackup

authorityBackupRemotePort :: Int
authorityBackupRemotePort = Home.homeControlPlaneRemotePort Home.HomeAuthorityBackup

tlsRetentionNamespace :: String
tlsRetentionNamespace = Home.homeControlPlaneNamespace Home.HomeTlsRetention

tlsRetentionForwardTarget :: String
tlsRetentionForwardTarget = Home.homeControlPlaneForwardTarget Home.HomeTlsRetention

tlsRetentionRemotePort :: Int
tlsRetentionRemotePort = Home.homeControlPlaneRemotePort Home.HomeTlsRetention

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
  expectedLines = Home.homeControlPlaneForwardStartupLines Home.HomeAuthorityBackup localPort

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
  LifecycleAuthorityRuntime -> Home.homeControlPlaneStartupProbePath Home.HomeLifecycleAuthority
  ProviderWorkerRuntime -> Home.homeControlPlaneStartupProbePath Home.HomeProviderWorker
  AuthorityBackupRuntime -> Home.homeControlPlaneStartupProbePath Home.HomeAuthorityBackup
  TlsRetentionRuntime -> Home.homeControlPlaneStartupProbePath Home.HomeTlsRetention
  TargetSecretAgentRuntime -> Home.homeControlPlaneStartupProbePath Home.HomeTargetSecretAgent

readinessHttpConfig :: HttpConfig
readinessHttpConfig =
  defaultHttpConfig {httpRequestTimeoutMicros = 1000000}

lifecycleAuthorityClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'LifecycleAuthorityRuntime)
lifecycleAuthorityClient = lifecycleAuthorityClientWithResponseMaximum (100 * 1024 * 1024)

-- Birth and peer metadata use their decoder's admitted byte ceiling at the HTTP
-- read boundary, before any complete response can enter the controller heap.
lifecycleAuthorityClientWithResponseMaximum
  :: Int
  -> Int
  -> Either ControlPlaneClientError (ControlPlaneClient 'LifecycleAuthorityRuntime)
lifecycleAuthorityClientWithResponseMaximum maximumBytes localPort = do
  endpoint <- mkLifecycleAuthorityEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    lifecycleAuthorityHttpConfig
    maximumBytes
    endpoint

lifecycleAuthorityHttpConfig :: HttpConfig
lifecycleAuthorityHttpConfig =
  defaultHttpConfig {httpRequestTimeoutMicros = 30 * 1000 * 1000}

lifecycleAuthorityProviderHttpConfig :: HttpConfig
lifecycleAuthorityProviderHttpConfig =
  defaultHttpConfig
    { httpRequestTimeoutMicros =
        ProviderWorkerBudget.providerWorkerResponseTimeoutMicros
    }

lifecycleAuthorityProviderClient
  :: Int
  -> Either
       ControlPlaneClientError
       (ControlPlaneClient 'LifecycleAuthorityRuntime)
lifecycleAuthorityProviderClient localPort = do
  endpoint <- mkLifecycleAuthorityEndpoint (Text.pack (loopbackEndpoint localPort))
  newControlPlaneClient
    lifecycleAuthorityProviderHttpConfig
    (100 * 1024 * 1024)
    endpoint

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
