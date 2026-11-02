{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The authenticated coordinator's closed home-Authority chart interpreter.
-- Held inputs and observed host placement grant neither Authority admission
-- nor a running-descriptor receipt; the coordinator independently owns both.
module Prodbox.ControlPlane.RpcAdmissionBirthRollout
  ( RpcBirthHostError (..)
  , RpcBirthRolloutError (..)
  , RpcBirthRolloutStage (..)
  , RpcBirthRolloutObservers (..)
  , productionRpcBirthRolloutObservers
  , rpcBirthRolloutExecutionKey
  , validateRpcBirthHomeKubeconfig
  , classifyRpcBirthRolloutRelease
  , validateRpcBirthJournalBinding
  , coordinateRpcBirthOnHost
  , coordinateRpcBirthOnHostWithObservers
  , coordinateRpcBirthOnOperation
  , coordinateRpcBirthOnOperationWithObservers
  , RpcBirthOperationPreparation
  , prepareRpcBirthOnOperation
  , prepareRpcBirthOnOperationWithObservers
  , coordinatePreparedRpcBirthOnOperation
  , mintPreparedRpcBirthCallerToken
  , RpcBirthCallerSigningSource (..)
  , RpcBirthOperationAuthentication
  , resolvePreparedRpcBirthCallerAuthentication
  , coordinateAuthenticatedRpcBirthOnOperation
  , coordinatePreparedRpcBirthCallerOnOperation
  ) where

import Codec.Serialise (serialise)
import Control.Exception (IOException, try)
import Control.Monad (forM_, unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', withObject, (.:))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.List (isPrefixOf, stripPrefix)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Prodbox.Capacity.RpcBirthTraffic (RpcBirthTrafficMode (..))
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry (controlPlaneSigningKeyRefFor)
import Prodbox.ControlPlane.Coordinate (authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalCallerTokenError
  , ExternalCallerTokenStage (..)
  , ExternalLifecycleAuthorityCaller
  , LifecycleAuthorityAuthenticationError (..)
  , externalCallerLoginWithToken
  , externalCallerPrincipal
  , externalCallerTokenSessionError
  , externalCallerTokenStageArguments
  , lifecycleAuthenticationConstants
  , mintExternalCallerTokenUsing
  )
import Prodbox.ControlPlane.LocalClient
  ( LocalLifecycleAuthorityError
  , OperationLifecycleAuthorityChannel
  , operationLifecycleAuthorityAuthenticatedTransport
  , requestOperationLifecycleAuthorityBootstrapRegistry
  , withOperationLifecycleAuthorityAuthenticatedTransport
  , withOperationLifecycleAuthorityChannel
  )
import Prodbox.ControlPlane.RegisteredRpcSigning
  ( RpcKeyRegistryObserver (..)
  , renderRegisteredRpcSigningError
  , resolveActiveRegisteredRpcSigningCapability
  , vaultNativeRpcSigningInterpreter
  , vaultRegisteredRpcSigningInterpreter
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , mkRequestSigningCapability
  , requestSigningCapabilityGeneration
  , requestSigningCapabilityPrincipal
  , requestSigningCapabilityPublicKeyBytes
  , signCanonicalBytesWithRequestCapability
  )
import Prodbox.ControlPlane.RetainedAuthentication (readRetainedAuthorityEpoch)
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthChart
import Prodbox.ControlPlane.RpcAdmissionBirthClock qualified as Clock
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
  ( RpcBirthConfig (..)
  , RpcBirthConfigError
  , validateRpcBirthConfig
  )
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthExecution (rpcBirthObservedRegistry)
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthPublication (tier0RpcBirthPublicationAtPath)
import Prodbox.ControlPlane.RpcBirthSigningBudget
  ( newRpcBirthNonceBudget
  , nextRpcBirthBudgetedNonce
  )
import Prodbox.ControlPlane.RpcKeyRegistry
  ( RpcKeyRegistry
  , RpcKeyRegistryError (RpcKeyRegistryObservationUnavailable)
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( freshAuthenticatedClientNonce
  , resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
import Prodbox.Infra.MinioBackend (resolveHomeClusterKubeconfig)
import Prodbox.Lib.ChartPlatform
  ( ChartPlanObservers (..)
  , ResolvedCustomImage (..)
  , customImageTagFromMachineId
  , parseKubernetesApiEgressCoordinate
  , selectRepositoryManifestDigest
  )
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , chartStorageClassName
  , renderChartStorageAccessMode
  )
import Prodbox.Lifecycle.HelmRelease qualified as Helm
import Prodbox.Lifecycle.Lease (AuthorityDuration, AuthorityTime)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EmbeddedHomeKubeconfig
  , embeddedHomeKubeconfigBytes
  , forbiddenKubectlEnvironmentKey
  , prepareEmbeddedHomeKubeconfig
  , writeEmbeddedHomeKubeconfig
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Settings
  ( ValidatedDeploymentContext
  , ValidatedSettings (validatedDeploymentContext)
  , deploymentClusterId
  , deploymentRpcRegistration
  , deploymentVaultAddress
  )
import Prodbox.Subprocess
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Substrate (Substrate (..))
import Prodbox.Vault.Client (VaultAddress (..))
import Prodbox.Vault.Session
  ( VaultSession
  , VaultSessionError (..)
  , newVaultSession
  , realSessionClock
  , sessionToken
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.IO.Temp (createTempDirectory, withTempDirectory)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data RpcBirthRolloutStage
  = RolloutCaptureHomeConfig
  | RolloutObserveRuntimeImage
  | RolloutObserveApiEgress
  | RolloutObserveRelease
  | RolloutObserveJournalClaim
  | RolloutObserveJournalVolume
  | RolloutApplyChart
  | RolloutConfirmRelease
  | RolloutObserveCallerServiceAccount
  | RolloutCheckCallerTokenEligibility
  | RolloutRequestCallerToken
  | RolloutAuthenticateCaller
  deriving (Eq, Show)

data RpcBirthRolloutError
  = RpcBirthRolloutHostIdentityMismatch
  | RpcBirthRolloutWindowOutsideAuthorityBound
  | RpcBirthRolloutDeadlineReached
  | RpcBirthRolloutHomeConfigUnavailable
  | RpcBirthRolloutHomeConfigInvalid
  | RpcBirthRolloutRuntimeImageInvalid
  | RpcBirthRolloutApiEgressInvalid
  | RpcBirthRolloutChartRefused !RpcBirthChartError
  | RpcBirthRolloutChildRefused !RpcBirthRolloutStage !HostSubprocessError
  | RpcBirthRolloutOperationRefused !RpcBirthRolloutStage !OperationSubprocessError
  | RpcBirthRolloutTransportRefused !LocalLifecycleAuthorityError
  | RpcBirthRolloutCommandFailed !RpcBirthRolloutStage
  | RpcBirthRolloutReleaseUnobservable
  | RpcBirthRolloutConcurrentRelease !Helm.HelmReleaseStatus
  | RpcBirthRolloutRetainedRelease !Helm.HelmReleaseStatus
  | RpcBirthRolloutReleaseNotDeployed
  | RpcBirthRolloutJournalMismatch
  | RpcBirthRolloutIoRefused
  | RpcBirthRolloutCallerTokenRefused !ExternalCallerTokenError
  | RpcBirthRolloutCallerAuthenticationRefused !LifecycleAuthorityAuthenticationError
  | RpcBirthRolloutCallerSessionRefused !VaultSessionError
  | RpcBirthRolloutCallerSigningModeMismatch
  | RpcBirthRolloutCallerConfigRefused !RpcBirthConfigError
  | RpcBirthRolloutCallerAuthenticationBudgetInvalid
  deriving (Eq, Show)

data RpcBirthHostError
  = RpcBirthHostPreparationRefused !RpcBirthRolloutError
  | RpcBirthHostCoordinationRefused !RpcBirthCoordinationError
  deriving (Eq, Show)

-- Only home-config discovery is replaceable. Production command selection and
-- child ownership remain the same under this deterministic observation seam.
newtype RpcBirthRolloutObservers = RpcBirthRolloutObservers
  { observeRpcBirthHomeKubeconfig :: IO (Either Text FilePath)
  }

productionRpcBirthRolloutObservers :: RpcBirthRolloutObservers
productionRpcBirthRolloutObservers =
  RpcBirthRolloutObservers (first Text.pack <$> resolveHomeClusterKubeconfig)

-- No constructor or raw-template/configuration setter is exported. This binds
-- one canonical preparation to the exact operation and original request.
data RpcBirthOperationPreparation
  = RpcBirthOperationPreparation
      !OperationSubprocesses
      !RpcBirthCoordinationRequest
      !EmbeddedHomeKubeconfig
      ![(String, String)]
      !RpcBirthChartTemplate
      !ValidatedDeploymentContext

-- The held preparation supplies the original owner, credentials and clocks.
-- A token is data for the separate Vault authentication boundary, not an RPC
-- signing capability or an Authority admission receipt.
mintPreparedRpcBirthCallerToken
  :: ExternalLifecycleAuthorityCaller
  -> RpcBirthOperationPreparation
  -> IO (Either RpcBirthHostError Text)
mintPreparedRpcBirthCallerToken caller (RpcBirthOperationPreparation processes request config environment _ _) =
  fmap (first RpcBirthHostPreparationRefused) . rolloutIO . runExceptT $ do
    validateOperationRequest processes request
    directory <- lift (createTempDirectory (operationSubprocessRuntimeDirectory processes) "caller-")
    kubeconfig <-
      ExceptT (first (const RpcBirthRolloutIoRefused) <$> writeEmbeddedHomeKubeconfig directory config)
    let run :: ExternalCallerTokenStage -> Rollout (Either () ProcessOutput)
        run stage =
          Right
            <$> operationCommand
              processes
              request
              environment
              (tokenStage stage)
              "kubectl"
              ( ["--kubeconfig", kubeconfig, "--cache-dir", directory </> "cache"]
                  ++ externalCallerTokenStageArguments caller stage
              )
    result <- mintExternalCallerTokenUsing run caller
    _ <- remainingOperationWork processes request
    either (throwE . RpcBirthRolloutCallerTokenRefused) pure result
 where
  tokenStage stage = case stage of
    ObserveExternalCallerServiceAccount -> RolloutObserveCallerServiceAccount
    CheckExternalCallerTokenEligibility -> RolloutCheckCallerTokenEligibility
    RequestExternalCallerToken -> RolloutRequestCallerToken

data RpcBirthCallerSigningSource
  = RpcBirthInitialCallerSigning
  | RpcBirthRegisteredCallerSigning !RpcKeyRegistry !(RpcKeyRegistryObserver IO)

-- No provider/session setters are exposed. Authentication retains exactly the
-- preparation whose physical owner and original clocks guard its effects.
data RpcBirthOperationAuthentication
  = RpcBirthOperationAuthentication
      !RpcBirthOperationPreparation
      !AuthenticatedTransportBounds
      !(AuthenticatedClientProviders IO)

resolvePreparedRpcBirthCallerAuthentication
  :: ExternalLifecycleAuthorityCaller
  -> RpcBirthCallerSigningSource
  -> RpcBirthOperationPreparation
  -> IO (Either RpcBirthHostError RpcBirthOperationAuthentication)
resolvePreparedRpcBirthCallerAuthentication caller source prepared@(RpcBirthOperationPreparation _ request _ _ _ context) = do
  bounded <- boundedCallerAuthentication prepared (runExceptT construct)
  pure (first RpcBirthHostPreparationRefused (bounded >>= id))
 where
  scope = rpcBirthCoordinationScope request
  principal = externalCallerPrincipal caller
  ref = controlPlaneSigningKeyRefFor principal
  construct = do
    _ <- validatePreparedCallerContext prepared
    case (deploymentRpcRegistration context, source) of
      (RpcBirthConfigLegacy, RpcBirthInitialCallerSigning) -> pure ()
      (RpcBirthConfigRegistered _, RpcBirthRegisteredCallerSigning _ _) -> pure ()
      (RpcBirthConfigLegacy, RpcBirthRegisteredCallerSigning _ _) ->
        throwE RpcBirthRolloutCallerSigningModeMismatch
      (RpcBirthConfigRegistered _, RpcBirthInitialCallerSigning) ->
        throwE RpcBirthRolloutCallerSigningModeMismatch
    (bounds, lifetime, session) <- newPreparedCallerSession caller prepared
    signer <-
      ExceptT $
        fmap (first RpcBirthRolloutCallerAuthenticationRefused) $
          case source of
            RpcBirthInitialCallerSigning ->
              first LifecycleAuthoritySigningCapabilityUnavailable
                <$> resolveTransitRequestSigningCapability session principal ref
            RpcBirthRegisteredCallerSigning registry observer ->
              first (LifecycleAuthoritySigningCapabilityUnavailable . renderRegisteredRpcSigningError)
                <$> resolveActiveRegisteredRpcSigningCapability
                  (vaultRegisteredRpcSigningInterpreter scope scope ref session observer)
                  registry
    owned <- preparedCallerProviders prepared session lifetime signer
    pure (RpcBirthOperationAuthentication prepared bounds owned)

validatePreparedCallerContext :: RpcBirthOperationPreparation -> Rollout RpcBirthServingMode
validatePreparedCallerContext (RpcBirthOperationPreparation _ request _ _ _ context) = do
  let scope = rpcBirthCoordinationScope request
  unless
    (mkAuthorityScope (deploymentClusterId context) == Right scope)
    (throwE RpcBirthRolloutHostIdentityMismatch)
  either
    (throwE . RpcBirthRolloutCallerConfigRefused)
    pure
    (validateRpcBirthConfig LifecycleAuthorityRuntime scope (deploymentRpcRegistration context))

newPreparedCallerSession
  :: ExternalLifecycleAuthorityCaller
  -> RpcBirthOperationPreparation
  -> Rollout (AuthenticatedTransportBounds, AuthorityDuration, VaultSession)
newPreparedCallerSession caller prepared@(RpcBirthOperationPreparation _ _ _ _ _ context) = do
  (bounds, lifetime) <-
    either (throwE . RpcBirthRolloutCallerAuthenticationRefused) pure lifecycleAuthenticationConstants
  session <- lift (newVaultSession address realSessionClock login)
  _ <- ExceptT (first RpcBirthRolloutCallerSessionRefused <$> sessionToken session)
  pure (bounds, lifetime, session)
 where
  address = VaultAddress (deploymentVaultAddress context)
  login = do
    token <- mintPreparedRpcBirthCallerToken caller prepared
    case token of
      Left (RpcBirthHostPreparationRefused (RpcBirthRolloutCallerTokenRefused failure)) ->
        pure (Left (externalCallerTokenSessionError caller failure))
      Left (RpcBirthHostPreparationRefused _) ->
        pure (Left (VaultSessionUnavailable "caller token owner or original bound refused"))
      Left (RpcBirthHostCoordinationRefused _) ->
        pure (Left (VaultSessionUnavailable "caller token preparation refused"))
      Right jwt -> externalCallerLoginWithToken address caller jwt

preparedCallerProviders
  :: RpcBirthOperationPreparation
  -> VaultSession
  -> AuthorityDuration
  -> RequestSigningCapability IO
  -> Rollout (AuthenticatedClientProviders IO)
preparedCallerProviders prepared@(RpcBirthOperationPreparation _ request _ _ _ _) session lifetime signer = do
  guarded <-
    either
      ( const
          ( throwE
              ( RpcBirthRolloutCallerAuthenticationRefused
                  (LifecycleAuthoritySigningCapabilityUnavailable "caller signing capability invalid")
              )
          )
      )
      pure
      ( mkRequestSigningCapability
          (requestSigningCapabilityPrincipal signer)
          (requestSigningCapabilityGeneration signer)
          (requestSigningCapabilityPublicKeyBytes signer)
          ( \bytes ->
              withCallerAuthenticationBound
                prepared
                (first (Text.pack . show) <$> signCanonicalBytesWithRequestCapability signer bytes)
          )
      )
  let providers =
        transitAuthenticatedClientProviders
          guarded
          (pure (Right (rpcBirthCoordinationScope request)))
          (readRetainedAuthorityEpoch session)
          lifetime
  pure
    AuthenticatedClientProviders
      { provideAuthenticatedClientSigner =
          withCallerAuthenticationBound prepared (provideAuthenticatedClientSigner providers)
      , provideAuthenticatedClientScope =
          withCallerAuthenticationBound prepared (provideAuthenticatedClientScope providers)
      , provideAuthenticatedClientEpoch =
          withCallerAuthenticationBound prepared (provideAuthenticatedClientEpoch providers)
      , provideAuthenticatedClientDeadline =
          withCallerAuthenticationBound prepared (pure (Right (rpcBirthCoordinationDeadline request)))
      , provideAuthenticatedClientNonce =
          withCallerAuthenticationBound prepared (provideAuthenticatedClientNonce providers)
      }

-- One total owner: no session, observer, provider or temporary signer leaves
-- this scope. Both metadata bootstrap and coordination use the same forward.
coordinatePreparedRpcBirthCallerOnOperation
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> RpcBirthOperationPreparation
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinatePreparedRpcBirthCallerOnOperation caller sourcePath prepared@(RpcBirthOperationPreparation processes request config environment template _) = do
  attempted <- try run
  pure $ case attempted of
    Left (_ :: IOException) -> Left (RpcBirthHostPreparationRefused RpcBirthRolloutIoRefused)
    Right result -> result
 where
  run = do
    admitted <-
      boundedCallerAuthentication prepared (runExceptT (validatePreparedCallerContext prepared))
    case admitted >>= id of
      Left cause -> pure (Left (RpcBirthHostPreparationRefused cause))
      Right mode -> do
        result <- withOperationLifecycleAuthorityChannel processes config environment $ \channel -> do
          resolved <- boundedCallerAuthentication prepared (runExceptT (resolveOnChannel mode channel))
          case resolved >>= id of
            Left cause -> pure (Left (RpcBirthHostPreparationRefused cause))
            Right (bounds, providers) ->
              coordinateCaptured
                ( HeldOperationRollout
                    processes
                    (operationLifecycleAuthorityAuthenticatedTransport bounds providers channel)
                )
                request
                sourcePath
                template
                config
                environment
        pure (either (Left . RpcBirthHostPreparationRefused . RpcBirthRolloutTransportRefused) id result)
  resolveOnChannel
    :: RpcBirthServingMode
    -> OperationLifecycleAuthorityChannel
    -> Rollout (AuthenticatedTransportBounds, AuthenticatedClientProviders IO)
  resolveOnChannel mode channel = do
    (bounds, lifetime, session) <- newPreparedCallerSession caller prepared
    let trafficMode = case rpcBirthServingModeRequiresRegistration mode of
          False -> RpcBirthInitialTraffic
          True -> RpcBirthRegisteredTraffic
    nonceBudget <- lift (newRpcBirthNonceBudget trafficMode freshAuthenticatedClientNonce)
    let scope = rpcBirthCoordinationScope request
        principal = externalCallerPrincipal caller
        ref = controlPlaneSigningKeyRefFor principal
        native = vaultNativeRpcSigningInterpreter scope ref session
        nonce = do
          generated <- nextRpcBirthBudgetedNonce nonceBudget
          pure (first (Text.pack . show) generated >>= id)
        readRegistry =
          fmap (fmap rpcBirthObservedRegistry) $
            requestOperationLifecycleAuthorityBootstrapRegistry
              channel
              native
              (Right <$> rpcBirthSystemTime)
              nonce
              scope
              mode
              (rpcBirthCoordinationDeadline request)
              bounds
        observer = RpcKeyRegistryObserver (first (const RpcKeyRegistryObservationUnavailable) <$> readRegistry)
    signer <- case rpcBirthServingModeRequiresRegistration mode of
      False ->
        ExceptT
          ( first (RpcBirthRolloutCallerAuthenticationRefused . LifecycleAuthoritySigningCapabilityUnavailable)
              <$> resolveTransitRequestSigningCapability session principal ref
          )
      True -> do
        registry <- ExceptT (first RpcBirthRolloutTransportRefused <$> readRegistry)
        ExceptT
          ( first
              ( RpcBirthRolloutCallerAuthenticationRefused
                  . LifecycleAuthoritySigningCapabilityUnavailable
                  . renderRegisteredRpcSigningError
              )
              <$> resolveActiveRegisteredRpcSigningCapability
                (vaultRegisteredRpcSigningInterpreter scope scope ref session observer)
                registry
          )
    providers <- preparedCallerProviders prepared session lifetime signer
    pure
      (bounds, providers {provideAuthenticatedClientNonce = withCallerAuthenticationBound prepared nonce})

coordinateAuthenticatedRpcBirthOnOperation
  :: FilePath
  -> RpcBirthOperationAuthentication
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateAuthenticatedRpcBirthOnOperation sourcePath (RpcBirthOperationAuthentication prepared bounds providers) =
  coordinatePreparedRpcBirthOnOperation bounds providers sourcePath prepared

withCallerAuthenticationBound
  :: RpcBirthOperationPreparation
  -> IO (Either Text value)
  -> IO (Either Text value)
withCallerAuthenticationBound prepared action = do
  bounded <- boundedCallerAuthentication prepared action
  pure (either (Left . Text.pack . show) id bounded)

-- The cached session and its providers can only be reached through this bound.
-- A timeout or callback completion never renews the original operation window.
boundedCallerAuthentication
  :: RpcBirthOperationPreparation
  -> IO value
  -> IO (Either RpcBirthRolloutError value)
boundedCallerAuthentication (RpcBirthOperationPreparation processes request _ _ _ _) action =
  rolloutIO . runExceptT $ do
    validateOperationRequestAt RolloutAuthenticateCaller processes request
    remaining <- remainingOperationWork processes request
    let micros = remaining `div` 1000
    when (micros == 0) (throwE RpcBirthRolloutDeadlineReached)
    when
      (toInteger micros > toInteger (maxBound :: Int))
      (throwE RpcBirthRolloutCallerAuthenticationBudgetInvalid)
    result <- lift (timeout (fromIntegral micros) action)
    validateOperationRequestAt RolloutAuthenticateCaller processes request
    maybe (throwE RpcBirthRolloutDeadlineReached) pure result

prepareRpcBirthOnOperation
  :: OperationSubprocesses
  -> RpcBirthCoordinationRequest
  -> FilePath
  -> ValidatedSettings
  -> IO (Either RpcBirthHostError RpcBirthOperationPreparation)
prepareRpcBirthOnOperation = prepareRpcBirthOnOperationWithObservers productionRpcBirthRolloutObservers

-- Discovery alone is replaceable; both metadata reads still use real admitted
-- command roles, the same embedded home credential and original operation end.
prepareRpcBirthOnOperationWithObservers
  :: RpcBirthRolloutObservers
  -> OperationSubprocesses
  -> RpcBirthCoordinationRequest
  -> FilePath
  -> ValidatedSettings
  -> IO (Either RpcBirthHostError RpcBirthOperationPreparation)
prepareRpcBirthOnOperationWithObservers observers processes request repoRoot settings =
  fmap (first RpcBirthHostPreparationRefused) . rolloutIO . runExceptT $ do
    validateOperationRequest processes request
    directory <- lift (createTempDirectory (operationSubprocessRuntimeDirectory processes) "prepare-")
    let check = remainingOperationWork processes request
        run = operationCommand processes request
    (config, environment) <- captureHomeInputs observers check run directory
    kubeconfig <-
      ExceptT (first (const RpcBirthRolloutIoRefused) <$> writeEmbeddedHomeKubeconfig directory config)
    _ <- check
    machineId <- lift (withBinaryFile "/etc/machine-id" ReadMode (\handle -> BS.hGet handle 65))
    when (BS.length machineId >= 65) (throwE RpcBirthRolloutRuntimeImageInvalid)
    tag <-
      either
        (const (throwE RpcBirthRolloutRuntimeImageInvalid))
        pure
        (customImageTagFromMachineId (Bytes.unpack machineId))
    let repository = ContainerImage.harborRuntimeImageRepository
    imageOutput <-
      run
        environment
        RolloutObserveRuntimeImage
        "docker"
        [ "image"
        , "inspect"
        , "--format"
        , "{\"id\":{{json .Id}},\"digests\":{{json .RepoDigests}}}"
        , repository ++ ":" ++ tag
        ]
    image <- either throwE pure (runtimeImageObservation repository tag imageOutput)
    apiOutput <-
      run
        environment
        RolloutObserveApiEgress
        "kubectl"
        [ "--kubeconfig"
        , kubeconfig
        , "--cache-dir"
        , directory </> "cache" </> "kubectl"
        , "get"
        , "endpoints"
        , "kubernetes"
        , "--namespace"
        , "default"
        , "-o"
        , "jsonpath={.subsets[*].addresses[*].ip}|{.subsets[*].ports[*].port}"
        ]
    unless
      (processExitCode apiOutput == ExitSuccess)
      (throwE (RpcBirthRolloutCommandFailed RolloutObserveApiEgress))
    coordinate <-
      either
        (const (throwE RpcBirthRolloutApiEgressInvalid))
        pure
        (parseKubernetesApiEgressCoordinate (processStdout apiOutput))
    let held =
          ChartPlanObservers
            ( \substrate -> pure $ case substrate of
                SubstrateHomeLocal -> Right (Just image)
                SubstrateAws -> Left "RPC birth preparation requires the retained home Authority"
            )
            (pure (Right coordinate))
    template <-
      ExceptT
        ( first RpcBirthRolloutChartRefused
            <$> prepareRpcBirthChartWithObservers held (rpcBirthCoordinationScope request) repoRoot settings
        )
    validateOperationRequest processes request
    pure
      ( RpcBirthOperationPreparation
          processes
          request
          config
          environment
          template
          (validatedDeploymentContext settings)
      )

runtimeImageObservation
  :: String -> String -> ProcessOutput -> Either RpcBirthRolloutError ResolvedCustomImage
runtimeImageObservation repository tag output = do
  unless
    (processExitCode output == ExitSuccess)
    (Left (RpcBirthRolloutCommandFailed RolloutObserveRuntimeImage))
  value <-
    first
      (const RpcBirthRolloutRuntimeImageInvalid)
      (eitherDecodeStrict' (Bytes.pack (processStdout output)))
  (imageId, references) <-
    first
      (const RpcBirthRolloutRuntimeImageInvalid)
      ( parseEither
          (withObject "runtime image metadata" (\fields -> (,) <$> fields .: "id" <*> fields .: "digests"))
          value
      )
  unless
    (selectRepositoryManifestDigest repository [repository ++ "@" ++ imageId] == Just imageId)
    (Left RpcBirthRolloutRuntimeImageInvalid)
  digest <-
    maybe
      (Left RpcBirthRolloutRuntimeImageInvalid)
      Right
      (selectRepositoryManifestDigest repository references)
  pure (ResolvedCustomImage repository tag (Just imageId) (Just digest))

coordinatePreparedRpcBirthOnOperation
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> FilePath
  -> RpcBirthOperationPreparation
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinatePreparedRpcBirthOnOperation bounds providers sourcePath (RpcBirthOperationPreparation processes request config environment template _) = do
  attempted <- try run
  pure $ case attempted of
    Left (_ :: IOException) -> Left (RpcBirthHostPreparationRefused RpcBirthRolloutIoRefused)
    Right result -> result
 where
  run = do
    admitted <- runExceptT (validateOperationRequest processes request)
    case admitted of
      Left cause -> pure (Left (RpcBirthHostPreparationRefused cause))
      Right () ->
        coordinateCaptured
          (OperationRollout processes bounds providers)
          request
          sourcePath
          template
          config
          environment

rpcBirthRolloutExecutionKey
  :: RpcBirthCoordinationRequest -> Either RpcBirthRolloutError HostExecutionKey
rpcBirthRolloutExecutionKey request =
  maybe (Left RpcBirthRolloutHostIdentityMismatch) Right (hostExecutionKeyFromText digest)
 where
  digest = concatMap hex (BS.unpack (SHA256.hash payload))
  payload =
    Lazy.toStrict $
      serialise
        ( "prodbox-rpc-birth-host/v1" :: Text
        , authorityScopeText (rpcBirthCoordinationScope request)
        , rpcBirthCoordinationGeneration request
        , rpcBirthCoordinationKey request
        )
  hex byte = [digit (byte `div` 16), digit (byte `mod` 16)]
  digit value = "0123456789abcdef" !! fromIntegral value

validateRpcBirthHomeKubeconfig :: ByteString -> Either RpcBirthRolloutError ByteString
validateRpcBirthHomeKubeconfig bytes =
  first
    (const RpcBirthRolloutHomeConfigInvalid)
    (embeddedHomeKubeconfigBytes <$> prepareEmbeddedHomeKubeconfig bytes)

classifyRpcBirthRolloutRelease :: ProcessOutput -> Either RpcBirthRolloutError ()
classifyRpcBirthRolloutRelease output = case Helm.helmUpgradePreparation (Helm.classifyHelmReleaseStatus output) of
  Right Helm.HelmUpgradeAdmit -> Right ()
  Right (Helm.HelmUpgradeRequireExactAbsence status) -> Left (RpcBirthRolloutRetainedRelease status)
  Left (Helm.HelmWriteConcurrentOperation status) -> Left (RpcBirthRolloutConcurrentRelease status)
  Left (Helm.HelmWriteUnobservable _) -> Left RpcBirthRolloutReleaseUnobservable

-- Read the exact retained claim/volume pair. The volume's claim UID prevents a
-- same-name replacement claim from adopting this observation's storage proof.
validateRpcBirthJournalBinding
  :: ChartStorageBinding -> Value -> Value -> Either RpcBirthRolloutError ()
validateRpcBirthJournalBinding binding claim volume = do
  uid <- case field ["metadata", "uid"] claim of
    Just actual@(String text) | not (Text.null text) -> Right actual
    _ -> mismatch
  unless
    ( chartStorageBindingStatefulSetName binding == "lifecycle-authority"
        && chartStorageBindingReleaseName binding == "lifecycle-authority"
        && chartStorageBindingOrdinal binding == 0
        && matches claim ["kind"] "PersistentVolumeClaim"
        && matches claim ["metadata", "namespace"] "lifecycle-authority"
        && matches claim ["metadata", "name"] (chartStorageBindingPersistentVolumeClaimName binding)
        && matches claim ["status", "phase"] "Bound"
        && matches claim ["spec", "volumeName"] (chartStorageBindingPersistentVolumeName binding)
        && matches claim ["spec", "storageClassName"] chartStorageClassName
        && matches volume ["kind"] "PersistentVolume"
        && matches volume ["metadata", "name"] (chartStorageBindingPersistentVolumeName binding)
        && matches volume ["status", "phase"] "Bound"
        && matches volume ["spec", "persistentVolumeReclaimPolicy"] "Retain"
        && matches volume ["spec", "storageClassName"] chartStorageClassName
        && matches volume ["spec", "hostPath", "path"] (chartStorageBindingHostPath binding)
        && matches volume ["spec", "claimRef", "namespace"] "lifecycle-authority"
        && matches volume ["spec", "claimRef", "name"] (chartStorageBindingPersistentVolumeClaimName binding)
        && field ["spec", "claimRef", "uid"] volume == Just uid
        && field ["spec", "accessModes"] claim == Just access
        && field ["spec", "accessModes"] volume == Just access
        && sameSize claim ["spec", "resources", "requests", "storage"]
        && sameSize volume ["spec", "capacity", "storage"]
    )
    mismatch
 where
  mismatch :: Either RpcBirthRolloutError result
  mismatch = Left RpcBirthRolloutJournalMismatch
  access =
    Array
      ( Vector.singleton
          (String (Text.pack (renderChartStorageAccessMode (chartStorageBindingAccessMode binding))))
      )
  matches value path expected = field path value == Just (String (Text.pack expected))
  sameSize value path = case field path value of
    Just (String size) -> case (binaryBytes (Text.unpack size), binaryBytes (chartStorageBindingStorageSize binding)) of
      (Just actual, Just expected) -> actual == expected
      _ -> False
    _ -> False

-- The supported storage planner emits integral binary-SI sizes; Kubernetes may
-- normalize 1024Mi to 1Gi. Compare those canonical quantities in bytes.
binaryBytes :: String -> Maybe Integer
binaryBytes raw
  | length (take 65 raw) > 64 = Nothing
  | otherwise = case [ number * scale
                     | (suffix, scale) <- units
                     , Just digits <- [stripSuffix suffix raw]
                     , Just number <- [readMaybe digits]
                     , number > 0
                     ] of
      [value] -> Just value
      _ -> Nothing
 where
  units =
    [ ("Ki", 1024)
    , ("Mi", 1024 ^ (2 :: Int))
    , ("Gi", 1024 ^ (3 :: Int))
    , ("Ti", 1024 ^ (4 :: Int))
    , ("Pi", 1024 ^ (5 :: Int))
    , ("Ei", 1024 ^ (6 :: Int))
    , ("", 1)
    ]
  stripSuffix suffix value = reverse <$> stripPrefix (reverse suffix) (reverse value)

-- The two execution topologies retain separate typed process owners. The
-- operation arms retain the same managed command lane. The held arm reuses
-- its caller's scoped Authority channel instead of opening another forward.
data RolloutExecution
  = SerialRollout
      !HostSubprocessPlacement
      !OwnedSubprocessLimits
      !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
  | OperationRollout
      !OperationSubprocesses
      !AuthenticatedTransportBounds
      !(AuthenticatedClientProviders IO)
  | HeldOperationRollout
      !OperationSubprocesses
      !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)

coordinateRpcBirthOnHost
  :: HostSubprocessPlacement
  -> OwnedSubprocessLimits
  -> RpcBirthCoordinationRequest
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> FilePath
  -> RpcBirthChartTemplate
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateRpcBirthOnHost = coordinateRpcBirthOnHostWithObservers productionRpcBirthRolloutObservers

coordinateRpcBirthOnHostWithObservers
  :: RpcBirthRolloutObservers
  -> HostSubprocessPlacement
  -> OwnedSubprocessLimits
  -> RpcBirthCoordinationRequest
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> FilePath
  -> RpcBirthChartTemplate
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateRpcBirthOnHostWithObservers observers placement limits request transport =
  coordinateRpcBirthUsing observers (SerialRollout placement limits transport) request

coordinateRpcBirthOnOperation
  :: OperationSubprocesses
  -> RpcBirthCoordinationRequest
  -> AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> FilePath
  -> RpcBirthChartTemplate
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateRpcBirthOnOperation = coordinateRpcBirthOnOperationWithObservers productionRpcBirthRolloutObservers

coordinateRpcBirthOnOperationWithObservers
  :: RpcBirthRolloutObservers
  -> OperationSubprocesses
  -> RpcBirthCoordinationRequest
  -> AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> FilePath
  -> RpcBirthChartTemplate
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateRpcBirthOnOperationWithObservers observers processes request bounds providers =
  coordinateRpcBirthUsing observers (OperationRollout processes bounds providers) request

coordinateRpcBirthUsing
  :: RpcBirthRolloutObservers
  -> RolloutExecution
  -> RpcBirthCoordinationRequest
  -> FilePath
  -> RpcBirthChartTemplate
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateRpcBirthUsing observers execution request sourcePath template = do
  attempted <- try run
  pure $ case attempted of
    Left (_ :: IOException) -> Left (RpcBirthHostPreparationRefused RpcBirthRolloutIoRefused)
    Right result -> result
 where
  deadline = rpcBirthCoordinationDeadline request
  run = do
    admitted <- runExceptT $ do
      expectedKey <- either throwE pure (rpcBirthRolloutExecutionKey request)
      unless (executionKey execution == expectedKey) (throwE RpcBirthRolloutHostIdentityMismatch)
      _ <- remainingWork execution deadline
      case execution of
        SerialRollout {} -> pure ()
        OperationRollout processes _ _ ->
          ExceptT
            ( first (RpcBirthRolloutOperationRefused RolloutCaptureHomeConfig)
                <$> verifyOperationSubprocessesBeforeEffect processes
            )
        HeldOperationRollout processes _ ->
          ExceptT
            ( first (RpcBirthRolloutOperationRefused RolloutCaptureHomeConfig)
                <$> verifyOperationSubprocessesBeforeEffect processes
            )
    case admitted of
      Left cause -> pure (Left (RpcBirthHostPreparationRefused cause))
      Right () -> withExecutionDirectory execution "tools-" prepare
  prepare toolHome = do
    prepared <-
      rolloutIO $
        runExceptT $
          captureHomeInputs
            observers
            (remainingWork execution deadline)
            (\environment -> command execution environment deadline)
            toolHome
    case prepared of
      Left cause -> pure (Left (RpcBirthHostPreparationRefused cause))
      Right (config, environment) -> coordinateCaptured execution request sourcePath template config environment

coordinateCaptured
  :: RolloutExecution
  -> RpcBirthCoordinationRequest
  -> FilePath
  -> RpcBirthChartTemplate
  -> EmbeddedHomeKubeconfig
  -> [(String, String)]
  -> IO (Either RpcBirthHostError RpcBirthCoordinationResult)
coordinateCaptured execution request sourcePath template config environment =
  withExecutionTransport execution config environment $ \transport ->
    first RpcBirthHostCoordinationRefused
      <$> coordinateRpcBirthWithTransport
        (Right <$> rpcBirthSystemTime)
        (rpcBirthCoordinationScope request)
        (rpcBirthCoordinationDeadline request)
        (rpcBirthCoordinationGeneration request)
        (rpcBirthCoordinationKey request)
        transport
        ( tier0RpcBirthPublicationAtPath (rpcBirthCoordinationScope request) sourcePath $ \bound descriptor ->
            first (Text.pack . show) <$> reconcile execution environment config bound descriptor template
        )

captureHomeInputs
  :: RpcBirthRolloutObservers
  -> Rollout Word64
  -> ([(String, String)] -> RpcBirthRolloutStage -> FilePath -> [String] -> Rollout ProcessOutput)
  -> FilePath
  -> Rollout (EmbeddedHomeKubeconfig, [(String, String)])
captureHomeInputs observers check run toolHome = do
  _ <- check
  kubeconfig <-
    ExceptT
      (first (const RpcBirthRolloutHomeConfigUnavailable) <$> observeRpcBirthHomeKubeconfig observers)
  environment <- lift getEnvironment
  let heldEnvironment = toolEnvironment toolHome environment
  lift $ createDirectoryIfMissing True (toolHome </> "cache")
  output <-
    run
      heldEnvironment
      RolloutCaptureHomeConfig
      "kubectl"
      [ "--cache-dir"
      , toolHome </> "cache" </> "kubectl"
      , "--kubeconfig"
      , kubeconfig
      , "config"
      , "view"
      , "--raw"
      , "--flatten"
      , "--minify"
      , "--output=json"
      ]
  unless
    (processExitCode output == ExitSuccess)
    (throwE (RpcBirthRolloutCommandFailed RolloutCaptureHomeConfig))
  config <-
    either
      (const (throwE RpcBirthRolloutHomeConfigInvalid))
      pure
      (prepareEmbeddedHomeKubeconfig (Bytes.pack (processStdout output)))
  pure (config, heldEnvironment)

validateOperationRequest :: OperationSubprocesses -> RpcBirthCoordinationRequest -> Rollout ()
validateOperationRequest = validateOperationRequestAt RolloutCaptureHomeConfig

validateOperationRequestAt
  :: RpcBirthRolloutStage -> OperationSubprocesses -> RpcBirthCoordinationRequest -> Rollout ()
validateOperationRequestAt stage processes request = do
  expectedKey <- either throwE pure (rpcBirthRolloutExecutionKey request)
  unless
    (operationSubprocessExecutionKey processes == expectedKey)
    (throwE RpcBirthRolloutHostIdentityMismatch)
  _ <- remainingOperationWork processes request
  ExceptT
    ( first (RpcBirthRolloutOperationRefused stage)
        <$> verifyOperationSubprocessesBeforeEffect processes
    )

remainingOperationWork :: OperationSubprocesses -> RpcBirthCoordinationRequest -> Rollout Word64
remainingOperationWork processes request =
  let window = operationSubprocessWindow processes
   in remainingWorkInWindow
        (Identity.hostExecutionWorkEnd window, Identity.hostExecutionOuterEnd window)
        (rpcBirthCoordinationDeadline request)

operationCommand
  :: OperationSubprocesses
  -> RpcBirthCoordinationRequest
  -> [(String, String)]
  -> RpcBirthRolloutStage
  -> FilePath
  -> [String]
  -> Rollout ProcessOutput
operationCommand processes request environment stage executable arguments = do
  _ <- remainingOperationWork processes request
  captured <-
    ExceptT
      ( first (RpcBirthRolloutOperationRefused stage)
          <$> captureOperationCommand processes (Subprocess executable arguments (Just environment) Nothing)
      )
  _ <- remainingOperationWork processes request
  pure (operationOutput captured)

operationOutput :: OperationProcessOutput -> ProcessOutput
operationOutput captured =
  ProcessOutput
    (operationProcessExitCode captured)
    (Bytes.unpack (operationProcessStdout captured))
    (Bytes.unpack (operationProcessStderr captured))

withExecutionTransport
  :: RolloutExecution
  -> EmbeddedHomeKubeconfig
  -> [(String, String)]
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO (Either RpcBirthHostError value))
  -> IO (Either RpcBirthHostError value)
withExecutionTransport execution config environment action = case execution of
  SerialRollout _ _ transport -> action transport
  HeldOperationRollout _ transport -> action transport
  OperationRollout processes bounds providers -> do
    result <-
      withOperationLifecycleAuthorityAuthenticatedTransport
        processes
        config
        environment
        bounds
        providers
        action
    pure (either (Left . RpcBirthHostPreparationRefused . RpcBirthRolloutTransportRefused) id result)

executionKey :: RolloutExecution -> HostExecutionKey
executionKey execution = case execution of
  SerialRollout placement _ _ -> hostSubprocessExecutionKey placement
  OperationRollout processes _ _ -> operationSubprocessExecutionKey processes
  HeldOperationRollout processes _ -> operationSubprocessExecutionKey processes

executionWindow :: RolloutExecution -> (Word64, Word64)
executionWindow execution = case execution of
  SerialRollout placement _ _ -> (hostSubprocessWorkEnd placement, hostSubprocessOuterEnd placement)
  OperationRollout processes _ _ -> operationExecutionWindow processes
  HeldOperationRollout processes _ -> operationExecutionWindow processes

operationExecutionWindow :: OperationSubprocesses -> (Word64, Word64)
operationExecutionWindow processes =
  let window = operationSubprocessWindow processes
   in (Identity.hostExecutionWorkEnd window, Identity.hostExecutionOuterEnd window)

executionRuntimeDirectory :: RolloutExecution -> FilePath
executionRuntimeDirectory execution = case execution of
  SerialRollout placement _ _ -> hostSubprocessRuntimeDirectory placement
  OperationRollout processes _ _ -> operationSubprocessRuntimeDirectory processes
  HeldOperationRollout processes _ -> operationSubprocessRuntimeDirectory processes

withExecutionDirectory :: RolloutExecution -> String -> (FilePath -> IO value) -> IO value
withExecutionDirectory execution prefix action = case execution of
  SerialRollout {} -> withTempDirectory (executionRuntimeDirectory execution) prefix action
  OperationRollout {} -> createTempDirectory (executionRuntimeDirectory execution) prefix >>= action
  HeldOperationRollout {} -> createTempDirectory (executionRuntimeDirectory execution) prefix >>= action

type Rollout = ExceptT RpcBirthRolloutError IO

reconcile
  :: RolloutExecution
  -> [(String, String)]
  -> EmbeddedHomeKubeconfig
  -> AuthorityTime
  -> RpcBirthDescriptor
  -> RpcBirthChartTemplate
  -> IO (Either RpcBirthRolloutError ())
reconcile execution environment config deadline descriptor template = rolloutIO $
  withExecutionDirectory execution "chart-" $ \directory -> runExceptT $ do
    revision <-
      either (throwE . RpcBirthRolloutChartRefused) pure (pinRpcBirthChart template descriptor)
    let chart = directory </> "chart"
        values = directory </> "values.json"
    _ <- remainingWork execution deadline
    lift $ do
      createDirectoryIfMissing True (chart </> "templates")
      forM_ (rpcBirthChartFiles revision) $ \(name, bytes) -> privateFile (chart </> name) bytes
      privateFile values (rpcBirthChartValues revision)
    kubeconfig <-
      ExceptT (first (const RpcBirthRolloutIoRefused) <$> writeEmbeddedHomeKubeconfig directory config)
    let helm arguments =
          command
            execution
            environment
            deadline
            RolloutObserveRelease
            "helm"
            (arguments <> ["--kubeconfig", kubeconfig, "--namespace", "lifecycle-authority"])
    initial <- helm ["status", "lifecycle-authority", "--output=json"]
    either throwE pure (classifyRpcBirthRolloutRelease initial)
    verifyJournal execution environment kubeconfig deadline revision
    duration <- remainingWork execution deadline
    applied <-
      command
        execution
        environment
        deadline
        RolloutApplyChart
        "helm"
        [ "upgrade"
        , "--install"
        , "lifecycle-authority"
        , chart
        , "--namespace"
        , "lifecycle-authority"
        , "--kubeconfig"
        , kubeconfig
        , "--values"
        , values
        , "--wait"
        , "--timeout"
        , show duration <> "ns"
        ]
    -- Always observe after a returned exit, including nonzero/lost success.
    -- A failed apply remains a failure; a status alone cannot mint completion.
    closing <-
      command
        execution
        environment
        deadline
        RolloutConfirmRelease
        "helm"
        [ "status"
        , "lifecycle-authority"
        , "--output=json"
        , "--namespace"
        , "lifecycle-authority"
        , "--kubeconfig"
        , kubeconfig
        ]
    unless
      (processExitCode applied == ExitSuccess)
      (throwE (RpcBirthRolloutCommandFailed RolloutApplyChart))
    unless
      (Helm.classifyHelmReleaseStatus closing == Helm.HelmReleasePresent Helm.HelmStatusDeployed)
      (throwE RpcBirthRolloutReleaseNotDeployed)
    verifyJournal execution environment kubeconfig deadline revision

verifyJournal
  :: RolloutExecution
  -> [(String, String)]
  -> FilePath
  -> AuthorityTime
  -> RpcBirthChartRevision
  -> Rollout ()
verifyJournal execution environment kubeconfig deadline revision =
  case rpcBirthChartStorageBindings revision of
    [binding] -> do
      claim <-
        observe
          RolloutObserveJournalClaim
          [ "get"
          , "pvc"
          , chartStorageBindingPersistentVolumeClaimName binding
          , "--namespace"
          , "lifecycle-authority"
          ]
      volume <-
        observe RolloutObserveJournalVolume ["get", "pv", chartStorageBindingPersistentVolumeName binding]
      either throwE pure (validateRpcBirthJournalBinding binding claim volume)
    _ -> throwE RpcBirthRolloutJournalMismatch
 where
  cacheDirectory =
    maybe (executionRuntimeDirectory execution) id (lookup "HOME" environment)
      </> "cache"
      </> "kubectl"
  observe stage arguments = do
    output <-
      command
        execution
        environment
        deadline
        stage
        "kubectl"
        (arguments <> ["--cache-dir", cacheDirectory, "--kubeconfig", kubeconfig, "--output=json"])
    unless (processExitCode output == ExitSuccess) (throwE (RpcBirthRolloutCommandFailed stage))
    either
      (const (throwE RpcBirthRolloutJournalMismatch))
      pure
      (eitherDecodeStrict' (Bytes.pack (processStdout output)))

command
  :: RolloutExecution
  -> [(String, String)]
  -> AuthorityTime
  -> RpcBirthRolloutStage
  -> FilePath
  -> [String]
  -> Rollout ProcessOutput
command execution environment deadline stage executable arguments = do
  _ <- remainingWork execution deadline
  let spec = Subprocess executable arguments (Just environment) Nothing
  output <- case execution of
    SerialRollout placement limits _ -> do
      result <- lift (captureHostSubprocess placement limits spec)
      either (throwE . RpcBirthRolloutChildRefused stage) pure result
    OperationRollout processes _ _ -> captureCommand processes spec
    HeldOperationRollout processes _ -> captureCommand processes spec
  _ <- remainingWork execution deadline
  pure output
 where
  captureCommand processes spec = do
    result <- lift (captureOperationCommand processes spec)
    captured <- either (throwE . RpcBirthRolloutOperationRefused stage) pure result
    pure (operationOutput captured)

remainingWork :: RolloutExecution -> AuthorityTime -> Rollout Word64
remainingWork execution = remainingWorkInWindow (executionWindow execution)

remainingWorkInWindow :: (Word64, Word64) -> AuthorityTime -> Rollout Word64
remainingWorkInWindow window deadline =
  ExceptT $
    first cause <$> Clock.observeRpcBirthHostWindow window deadline
 where
  cause errorValue = case errorValue of
    Clock.RpcBirthHostClockExpired -> RpcBirthRolloutDeadlineReached
    Clock.RpcBirthHostClockOutsideAuthorityBound -> RpcBirthRolloutWindowOutsideAuthorityBound
    Clock.RpcBirthHostClockSampleInvalid -> RpcBirthRolloutDeadlineReached
    Clock.RpcBirthHostClockRemainingOverflow -> RpcBirthRolloutDeadlineReached

-- Keep all tool-created state under the manager-owned workspace. The source
-- kubeconfig is resolved before this replacement; PATH remains the caller's.
toolEnvironment :: FilePath -> [(String, String)] -> [(String, String)]
toolEnvironment directory environment =
  [ ("HOME", directory)
  , ("XDG_CACHE_HOME", directory </> "cache")
  , ("XDG_CONFIG_HOME", directory </> "config")
  , ("XDG_DATA_HOME", directory </> "data")
  , ("HELM_CACHE_HOME", directory </> "cache" </> "helm")
  , ("HELM_CONFIG_HOME", directory </> "config" </> "helm")
  , ("HELM_DATA_HOME", directory </> "data" </> "helm")
  ]
    <> filter
      ( \(name, _) ->
          not (forbiddenKubectlEnvironmentKey name)
            && name `notElem` ["HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]
            && not ("HELM_" `isPrefixOf` name)
      )
      environment

privateFile :: FilePath -> ByteString -> IO ()
privateFile path bytes = BS.writeFile path bytes >> setFileMode path 0o600

rolloutIO :: IO (Either RpcBirthRolloutError value) -> IO (Either RpcBirthRolloutError value)
rolloutIO action = do
  attempted <- try action
  pure $ case attempted of
    Left (_ :: IOException) -> Left RpcBirthRolloutIoRefused
    Right result -> result

field :: [Text] -> Value -> Maybe Value
field path value = case path of
  [] -> Just value
  name : rest -> case value of
    Object fields -> KeyMap.lookup (Key.fromText name) fields >>= field rest
    _ -> Nothing
