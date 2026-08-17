{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private, GET-only Lifecycle-Authority observer for the exact
-- ordinary-teardown recovery profile.  No caller can supply resource rows,
-- endpoints, credentials, or a ready result: the closed table below is the
-- sole dispatch source and the public facade exposes diagnostics only.
module Prodbox.Lifecycle.Teardown.RecoveryPlaneComponentObserver.Internal
  ( RecoveryPlaneComponentObserverError (..)
  , productionRecoveryPlaneComponentObserverInternal
  , RecoveryPlaneComponentObserverRegression
  , fixedRecoveryPlaneComponentObserverRegression
  , recoveryPlaneComponentObserverClosedInventory
  , recoveryPlaneComponentObserverReadyRowsExact
  , recoveryPlaneComponentObserverMissingRefused
  , recoveryPlaneComponentObserverMalformedRefused
  , recoveryPlaneComponentObserverUnauthorizedRefused
  , recoveryPlaneComponentObserverPartialRolloutRefused
  , recoveryPlaneComponentObserverInvalidUidRefused
  , recoveryPlaneComponentObserverGenerationMismatchRefused
  , recoveryPlaneComponentObserverConditionMismatchRefused
  , recoveryPlaneComponentObserverVaultSealedRefused
  , recoveryPlaneComponentObserverNetworkUnknownRefused
  , recoveryPlaneComponentObserverExternalCallerExact
  , recoveryPlaneComponentObserverOpacityClosed
  )
where

import Control.Exception (try)
import Control.Monad (unless)
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecodeStrict'
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( BodyReader
  , HttpException
  , Manager
  , Request (..)
  , brReadSome
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  , withResponse
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS
  ( ClientParams (..)
  , Shared (..)
  , defaultParamsClient
  )
import Prodbox.Bootstrap.Broker.ChartStatics
  ( brokerChartStatics
  , brokerStaticCleanupCallerServiceAccount
  , brokerStaticServiceAccount
  )
import Prodbox.Config.ComponentGraph (ComponentId (..))
import Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal
  ( LocalRke2HostObservationRepositoryClient
  , LocalRke2HostObservationRepositoryError (..)
  , independentlyReadBackLocalRke2HostObservationForRecoveryObservationInternal
  )
import Prodbox.ControlPlane.RecoveryPlaneRepository.Internal
  ( RecoveryPlaneObservationBinding
  )
import Prodbox.Gateway.Emitter.KubernetesLease
  ( projectedTokenSupplierAt
  )
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.K8s.InCluster
  ( inClusterCaCertPath
  , inClusterTokenPath
  , secretApiBaseUrl
  )
import Prodbox.Lifecycle.Authority.ChartStatics
  ( lifecycleAuthorityChartStatics
  , lifecycleAuthorityStaticServiceAccount
  )
import Prodbox.Lifecycle.AuthorityBackup.ChartStatics
  ( authorityBackupChartStatics
  , authorityBackupStaticServiceAccount
  )
import Prodbox.Lifecycle.ProviderWorker.ChartStatics
  ( providerWorkerChartStatics
  , providerWorkerStaticServiceAccount
  )
import Prodbox.Lifecycle.TargetSecretAgent.ChartStatics
  ( targetSecretAgentChartStatics
  , targetSecretAgentStaticServiceAccount
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneComponentIdentity (..)
  , RecoveryPlaneIdentity
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( RecoveryPlaneRawComponentResult (..)
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal qualified as RecoveryPlaneInterpreterInternal
import Prodbox.Vault.Client
  ( SealStatus (..)
  , VaultAddress (..)
  , vaultSealStatus
  )
import System.Timeout (timeout)

data RecoveryPlaneComponentObserverError
  = RecoveryPlaneComponentObserverCaUnavailable !Text
  | RecoveryPlaneComponentObserverManagerUnavailable !Text
  deriving stock (Eq, Show)

data RecoveryPlaneKubernetesResult
  = RecoveryPlaneKubernetesFound !ByteString
  | RecoveryPlaneKubernetesMissing
  | RecoveryPlaneKubernetesUnauthorized !Int
  | RecoveryPlaneKubernetesUnobservable !Text
  deriving stock (Eq, Show)

data RecoveryPlaneVaultResult
  = RecoveryPlaneVaultObserved !SealStatus
  | RecoveryPlaneVaultMissing
  | RecoveryPlaneVaultUnauthorized !Int
  | RecoveryPlaneVaultUnobservable !Text
  deriving stock (Eq, Show)

data RecoveryPlaneComponentObserverEffects m = RecoveryPlaneComponentObserverEffects
  { internalGetKubernetesObject
      :: RecoveryPlaneKubernetesObject
      -> m RecoveryPlaneKubernetesResult
  , internalObserveVaultSealStatus :: m RecoveryPlaneVaultResult
  }

data RecoveryPlaneKubernetesKind
  = RecoveryPlaneDeployment
  | RecoveryPlaneStatefulSet
  | RecoveryPlaneServiceAccount
  | RecoveryPlaneRole
  | RecoveryPlaneRoleBinding
  deriving stock (Eq, Ord, Show)

data RecoveryPlaneKubernetesObject = RecoveryPlaneKubernetesObject
  { internalKubernetesKind :: !RecoveryPlaneKubernetesKind
  , internalKubernetesNamespace :: !Text
  , internalKubernetesName :: !Text
  }
  deriving stock (Eq, Ord, Show)

data RecoveryPlaneWorkloadSpec = RecoveryPlaneWorkloadSpec
  { internalWorkloadComponent :: !ComponentId
  , internalWorkloadObject :: !RecoveryPlaneKubernetesObject
  , internalWorkloadServiceAccount :: !Text
  , internalWorkloadContainer :: !Text
  , internalWorkloadRequiresTargetAnnotations :: !Bool
  }
  deriving stock (Eq, Show)

data ComponentObserverEnvironment m = ComponentObserverEnvironment
  { internalHostRepository :: !(LocalRke2HostObservationRepositoryClient m)
  , internalObserverEffects :: !(RecoveryPlaneComponentObserverEffects m)
  }

maximumRecoveryPlaneKubernetesResponseBytes :: Int
maximumRecoveryPlaneKubernetesResponseBytes = 128 * 1024

recoveryPlaneKubernetesTimeoutMicros :: Int
recoveryPlaneKubernetesTimeoutMicros = 5 * 1000 * 1000

recoveryPlaneVaultAddress :: VaultAddress
recoveryPlaneVaultAddress = VaultAddress "http://vault.vault.svc.cluster.local:8200"

productionRecoveryPlaneComponentObserverInternal
  :: LocalRke2HostObservationRepositoryClient IO
  -> IO
       ( Either
           RecoveryPlaneComponentObserverError
           (RecoveryPlaneInterpreterInternal.RecoveryPlaneComponentObserver IO)
       )
productionRecoveryPlaneComponentObserverInternal hostRepository = do
  managerResult <- productionRecoveryPlaneKubernetesManager
  pure $ do
    manager <- managerResult
    let effects =
          RecoveryPlaneComponentObserverEffects
            { internalGetKubernetesObject =
                productionGetKubernetesObject
                  manager
                  (projectedTokenSupplierAt inClusterTokenPath)
            , internalObserveVaultSealStatus = productionObserveVault
            }
        observer =
          ComponentObserverEnvironment
            { internalHostRepository = hostRepository
            , internalObserverEffects = effects
            }
    Right
      ( RecoveryPlaneInterpreterInternal.RecoveryPlaneComponentObserver
          (observeRecoveryPlaneComponent observer)
      )

productionRecoveryPlaneKubernetesManager
  :: IO (Either RecoveryPlaneComponentObserverError Manager)
productionRecoveryPlaneKubernetesManager = do
  storeResult <- try (readCertificateStore inClusterCaCertPath)
  case storeResult of
    Left (err :: IOError) ->
      pure
        ( Left
            ( RecoveryPlaneComponentObserverCaUnavailable
                (Text.pack (show err))
            )
        )
    Right Nothing ->
      pure
        ( Left
            ( RecoveryPlaneComponentObserverCaUnavailable
                "projected Kubernetes CA could not be decoded"
            )
        )
    Right (Just store) -> do
      let host = "kubernetes.default.svc.cluster.local"
          baseParams = defaultParamsClient host ""
          clientParams =
            baseParams
              { clientShared =
                  (clientShared baseParams) {sharedCAStore = store}
              }
      managerResult <-
        try
          (newManager (mkManagerSettings (TLSSettings clientParams) Nothing))
      pure $ case managerResult of
        Left (err :: IOError) ->
          Left
            ( RecoveryPlaneComponentObserverManagerUnavailable
                (Text.pack (show err))
            )
        Right manager -> Right manager

productionGetKubernetesObject
  :: Manager
  -> IO (Either Text Text)
  -> RecoveryPlaneKubernetesObject
  -> IO RecoveryPlaneKubernetesResult
productionGetKubernetesObject manager tokenSupplier coordinate = do
  tokenResult <- tokenSupplier
  case tokenResult of
    Left detail -> pure (RecoveryPlaneKubernetesUnobservable detail)
    Right token -> do
      requestResult <-
        try
          ( parseRequest
              (secretApiBaseUrl ++ kubernetesObjectPath coordinate)
          )
      case requestResult of
        Left (err :: HttpException) ->
          pure
            ( RecoveryPlaneKubernetesUnobservable
                (Text.pack (show err))
            )
        Right baseRequest -> do
          let request =
                baseRequest
                  { method = "GET"
                  , requestHeaders =
                      [ ("Accept", "application/json")
                      ,
                        ( "Authorization"
                        , TextEncoding.encodeUtf8 ("Bearer " <> token)
                        )
                      ]
                  , responseTimeout =
                      responseTimeoutMicro recoveryPlaneKubernetesTimeoutMicros
                  }
          completed <-
            timeout
              recoveryPlaneKubernetesTimeoutMicros
              ( try
                  ( withResponse request manager $ \response -> do
                      bodyResult <-
                        collectBoundedResponseBody (responseBody response)
                      pure
                        ( statusCode (responseStatus response)
                        , bodyResult
                        )
                  )
                  :: IO
                       ( Either
                           HttpException
                           (Int, Either Text ByteString)
                       )
              )
          pure $ case completed of
            Nothing ->
              RecoveryPlaneKubernetesUnobservable
                "Kubernetes GET exceeded the fixed request deadline"
            Just (Left err) ->
              RecoveryPlaneKubernetesUnobservable (Text.pack (show err))
            Just (Right (code, bodyResult)) ->
              classifyKubernetesHttpResult code bodyResult

collectBoundedResponseBody
  :: BodyReader -> IO (Either Text ByteString)
collectBoundedResponseBody reader = collect 0 []
 where
  collect total reversed = do
    let remaining = maximumRecoveryPlaneKubernetesResponseBytes + 1 - total
    chunk <- brReadSome reader remaining
    if LazyByteString.null chunk
      then
        pure
          ( Right
              (LazyByteString.toStrict (LazyByteString.concat (reverse reversed)))
          )
      else do
        let totalAfter = total + fromIntegral (LazyByteString.length chunk)
        if totalAfter > maximumRecoveryPlaneKubernetesResponseBytes
          then
            pure
              ( Left
                  "Kubernetes GET response exceeds the 128 KiB bound"
              )
          else collect totalAfter (chunk : reversed)

classifyKubernetesHttpResult
  :: Int
  -> Either Text ByteString
  -> RecoveryPlaneKubernetesResult
classifyKubernetesHttpResult code bodyResult = case code of
  200 ->
    either RecoveryPlaneKubernetesUnobservable RecoveryPlaneKubernetesFound bodyResult
  401 -> RecoveryPlaneKubernetesUnauthorized code
  403 -> RecoveryPlaneKubernetesUnauthorized code
  404 -> RecoveryPlaneKubernetesMissing
  _ ->
    RecoveryPlaneKubernetesUnobservable
      ("Kubernetes GET returned HTTP " <> Text.pack (show code))

productionObserveVault :: IO RecoveryPlaneVaultResult
productionObserveVault = do
  observed <- vaultSealStatus recoveryPlaneVaultAddress
  pure $ case observed of
    Right status -> RecoveryPlaneVaultObserved status
    Left (HttpStatus 404 _) -> RecoveryPlaneVaultMissing
    Left (HttpStatus code _)
      | code == 401 || code == 403 -> RecoveryPlaneVaultUnauthorized code
    Left err ->
      RecoveryPlaneVaultUnobservable (Text.pack (renderHttpError err))

observeRecoveryPlaneComponent
  :: (Monad m)
  => ComponentObserverEnvironment m
  -> RecoveryPlaneIdentity surface
  -> RecoveryPlaneObservationBinding surface
  -> RecoveryPlaneComponentIdentity
  -> m RecoveryPlaneRawComponentResult
observeRecoveryPlaneComponent observer identity binding component =
  case component of
    RecoveryPlaneGraphComponent ComponentClusterBase ->
      observeClusterBase observer identity binding
    RecoveryPlaneGraphComponent ComponentMinio ->
      observeWorkload observer minioWorkload
    RecoveryPlaneGraphComponent ComponentVaultWorkload ->
      observeWorkload observer vaultWorkload
    RecoveryPlaneGraphComponent ComponentChartBootstrapBroker ->
      observeWorkload observer bootstrapBrokerWorkload
    RecoveryPlaneBootstrapCoreExternalCli ->
      observeBootstrapExternalCaller observer
    RecoveryPlaneGraphComponent ComponentVaultUnsealed ->
      observeVaultUnsealed observer
    RecoveryPlaneGraphComponent ComponentChartLifecycleAuthority ->
      observeWorkload observer lifecycleAuthorityWorkload
    RecoveryPlaneGraphComponent ComponentChartAuthorityBackup ->
      observeWorkload observer authorityBackupWorkload
    RecoveryPlaneGraphComponent ComponentChartProviderWorker ->
      observeWorkload observer providerWorkerWorkload
    RecoveryPlaneGraphComponent ComponentChartTargetSecretAgent ->
      observeWorkload observer targetSecretAgentWorkload
    RecoveryPlaneGraphComponent unsupported ->
      pure
        ( RecoveryPlaneRawUnobservable
            ( "component is outside the closed ordinary-teardown recovery profile: "
                <> Text.pack (show unsupported)
            )
        )

observeClusterBase
  :: (Monad m)
  => ComponentObserverEnvironment m
  -> RecoveryPlaneIdentity surface
  -> RecoveryPlaneObservationBinding surface
  -> m RecoveryPlaneRawComponentResult
observeClusterBase observer identity binding = do
  result <-
    independentlyReadBackLocalRke2HostObservationForRecoveryObservationInternal
      (internalHostRepository observer)
      identity
      binding
  pure $ case result of
    Right _ -> RecoveryPlaneRawReady
    Left LocalRke2HostObservationRepositoryMissing ->
      RecoveryPlaneRawMissing "current Establish attempt has no committed Healthy host observation"
    Left err ->
      RecoveryPlaneRawUnobservable
        ("Healthy host observation read-back refused: " <> Text.pack (show err))

observeWorkload
  :: (Monad m)
  => ComponentObserverEnvironment m
  -> RecoveryPlaneWorkloadSpec
  -> m RecoveryPlaneRawComponentResult
observeWorkload observer expected = do
  result <-
    internalGetKubernetesObject
      (internalObserverEffects observer)
      (internalWorkloadObject expected)
  pure (classifyWorkloadObservation expected result)

observeBootstrapExternalCaller
  :: (Monad m)
  => ComponentObserverEnvironment m
  -> m RecoveryPlaneRawComponentResult
observeBootstrapExternalCaller observer = do
  let getObject = internalGetKubernetesObject (internalObserverEffects observer)
  serviceAccountResult <- getObject bootstrapCallerServiceAccount
  roleResult <- getObject bootstrapCallerRole
  bindingResult <- getObject bootstrapCallerRoleBinding
  pure
    ( classifyBootstrapCallerObservations
        serviceAccountResult
        roleResult
        bindingResult
    )

observeVaultUnsealed
  :: (Monad m)
  => ComponentObserverEnvironment m
  -> m RecoveryPlaneRawComponentResult
observeVaultUnsealed observer = do
  result <- internalObserveVaultSealStatus (internalObserverEffects observer)
  pure (classifyVaultObservation result)

classifyWorkloadObservation
  :: RecoveryPlaneWorkloadSpec
  -> RecoveryPlaneKubernetesResult
  -> RecoveryPlaneRawComponentResult
classifyWorkloadObservation expected result = case result of
  RecoveryPlaneKubernetesMissing ->
    RecoveryPlaneRawMissing (renderKubernetesObject (internalWorkloadObject expected))
  RecoveryPlaneKubernetesUnauthorized code ->
    RecoveryPlaneRawUnavailable
      ("Kubernetes GET refused with HTTP " <> Text.pack (show code))
  RecoveryPlaneKubernetesUnobservable detail ->
    RecoveryPlaneRawUnobservable detail
  RecoveryPlaneKubernetesFound bytes ->
    case eitherDecodeStrict' bytes >>= validateWorkloadWire expected of
      Left detail -> RecoveryPlaneRawPartial (Text.pack detail :| [])
      Right () -> RecoveryPlaneRawReady

classifyBootstrapCallerObservations
  :: RecoveryPlaneKubernetesResult
  -> RecoveryPlaneKubernetesResult
  -> RecoveryPlaneKubernetesResult
  -> RecoveryPlaneRawComponentResult
classifyBootstrapCallerObservations serviceAccountResult roleResult bindingResult =
  case firstDefiniteFailure [serviceAccountResult, roleResult, bindingResult] of
    Just result -> classifyCallerTransportFailure result
    Nothing ->
      case (serviceAccountResult, roleResult, bindingResult) of
        ( RecoveryPlaneKubernetesFound serviceAccountBytes
          , RecoveryPlaneKubernetesFound roleBytes
          , RecoveryPlaneKubernetesFound bindingBytes
          ) ->
            case validateBootstrapCaller
              serviceAccountBytes
              roleBytes
              bindingBytes of
              Left detail -> RecoveryPlaneRawPartial (Text.pack detail :| [])
              Right () -> RecoveryPlaneRawReady
        _ ->
          RecoveryPlaneRawUnobservable
            "bootstrap caller observation did not produce a complete exact object trio"

firstDefiniteFailure
  :: [RecoveryPlaneKubernetesResult]
  -> Maybe RecoveryPlaneKubernetesResult
firstDefiniteFailure = find isDefiniteFailure

isDefiniteFailure :: RecoveryPlaneKubernetesResult -> Bool
isDefiniteFailure result = case result of
  RecoveryPlaneKubernetesFound _ -> False
  _ -> True

classifyCallerTransportFailure
  :: RecoveryPlaneKubernetesResult -> RecoveryPlaneRawComponentResult
classifyCallerTransportFailure result = case result of
  RecoveryPlaneKubernetesMissing ->
    RecoveryPlaneRawMissing "bootstrap-core external caller object trio is incomplete"
  RecoveryPlaneKubernetesUnauthorized code ->
    RecoveryPlaneRawUnavailable
      ("Kubernetes GET refused with HTTP " <> Text.pack (show code))
  RecoveryPlaneKubernetesUnobservable detail ->
    RecoveryPlaneRawUnobservable detail
  RecoveryPlaneKubernetesFound _ ->
    RecoveryPlaneRawUnobservable "internal caller-observation classification error"

classifyVaultObservation
  :: RecoveryPlaneVaultResult -> RecoveryPlaneRawComponentResult
classifyVaultObservation result = case result of
  RecoveryPlaneVaultMissing -> RecoveryPlaneRawMissing "Vault seal-status endpoint"
  RecoveryPlaneVaultUnauthorized code ->
    RecoveryPlaneRawUnavailable
      ("Vault seal-status refused with HTTP " <> Text.pack (show code))
  RecoveryPlaneVaultUnobservable detail -> RecoveryPlaneRawUnobservable detail
  RecoveryPlaneVaultObserved status
    | not (sealStatusInitialized status) ->
        RecoveryPlaneRawPartial ("Vault is not initialized" :| [])
    | sealStatusSealed status ->
        RecoveryPlaneRawPartial ("Vault is sealed" :| [])
    | otherwise -> RecoveryPlaneRawReady

data KubernetesMetadataWire = KubernetesMetadataWire
  { wireMetadataName :: !Text
  , wireMetadataNamespace :: !Text
  , wireMetadataUid :: !Text
  , wireMetadataGeneration :: !(Maybe Int)
  , wireMetadataAnnotations :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesMetadataWire where
  parseJSON = withObject "Kubernetes metadata" $ \value ->
    KubernetesMetadataWire
      <$> value .: "name"
      <*> value .: "namespace"
      <*> value .: "uid"
      <*> value .:? "generation"
      <*> value .:? "annotations" .!= Map.empty

data KubernetesContainerWire = KubernetesContainerWire
  { wireContainerName :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesContainerWire where
  parseJSON = withObject "Kubernetes container" $ \value ->
    KubernetesContainerWire <$> value .: "name"

data KubernetesPodSpecWire = KubernetesPodSpecWire
  { wirePodServiceAccountName :: !Text
  , wirePodContainers :: ![KubernetesContainerWire]
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesPodSpecWire where
  parseJSON = withObject "Kubernetes pod spec" $ \value ->
    KubernetesPodSpecWire
      <$> value .: "serviceAccountName"
      <*> value .: "containers"

data KubernetesPodTemplateWire = KubernetesPodTemplateWire
  { wirePodTemplateMetadata :: !KubernetesTemplateMetadataWire
  , wirePodTemplateSpec :: !KubernetesPodSpecWire
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesPodTemplateWire where
  parseJSON = withObject "Kubernetes pod template" $ \value ->
    KubernetesPodTemplateWire
      <$> value .:? "metadata" .!= KubernetesTemplateMetadataWire Map.empty
      <*> value .: "spec"

newtype KubernetesTemplateMetadataWire = KubernetesTemplateMetadataWire
  { wireTemplateAnnotations :: Map Text Text
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesTemplateMetadataWire where
  parseJSON = withObject "Kubernetes pod-template metadata" $ \value ->
    KubernetesTemplateMetadataWire
      <$> value .:? "annotations" .!= Map.empty

newtype KubernetesStrategyWire = KubernetesStrategyWire
  { wireStrategyType :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesStrategyWire where
  parseJSON = withObject "Kubernetes deployment strategy" $ \value ->
    KubernetesStrategyWire <$> value .: "type"

data KubernetesWorkloadSpecWire = KubernetesWorkloadSpecWire
  { wireSpecReplicas :: !Int
  , wireSpecTemplate :: !KubernetesPodTemplateWire
  , wireSpecStrategy :: !(Maybe KubernetesStrategyWire)
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesWorkloadSpecWire where
  parseJSON = withObject "Kubernetes workload spec" $ \value ->
    KubernetesWorkloadSpecWire
      <$> value .: "replicas"
      <*> value .: "template"
      <*> value .:? "strategy"

data KubernetesConditionWire = KubernetesConditionWire
  { wireConditionType :: !Text
  , wireConditionStatus :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesConditionWire where
  parseJSON = withObject "Kubernetes condition" $ \value ->
    KubernetesConditionWire
      <$> value .: "type"
      <*> value .: "status"

data KubernetesWorkloadStatusWire = KubernetesWorkloadStatusWire
  { wireStatusObservedGeneration :: !Int
  , wireStatusReplicas :: !Int
  , wireStatusReadyReplicas :: !Int
  , wireStatusUpdatedReplicas :: !Int
  , wireStatusAvailableReplicas :: !(Maybe Int)
  , wireStatusCurrentRevision :: !(Maybe Text)
  , wireStatusUpdateRevision :: !(Maybe Text)
  , wireStatusConditions :: ![KubernetesConditionWire]
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesWorkloadStatusWire where
  parseJSON = withObject "Kubernetes workload status" $ \value ->
    KubernetesWorkloadStatusWire
      <$> value .: "observedGeneration"
      <*> value .:? "replicas" .!= 0
      <*> value .:? "readyReplicas" .!= 0
      <*> value .:? "updatedReplicas" .!= 0
      <*> value .:? "availableReplicas"
      <*> value .:? "currentRevision"
      <*> value .:? "updateRevision"
      <*> value .:? "conditions" .!= []

data KubernetesWorkloadWire = KubernetesWorkloadWire
  { wireWorkloadApiVersion :: !Text
  , wireWorkloadKind :: !Text
  , wireWorkloadMetadata :: !KubernetesMetadataWire
  , wireWorkloadSpec :: !KubernetesWorkloadSpecWire
  , wireWorkloadStatus :: !KubernetesWorkloadStatusWire
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesWorkloadWire where
  parseJSON = withObject "Kubernetes workload" $ \value ->
    KubernetesWorkloadWire
      <$> value .: "apiVersion"
      <*> value .: "kind"
      <*> value .: "metadata"
      <*> value .: "spec"
      <*> value .: "status"

validateWorkloadWire
  :: RecoveryPlaneWorkloadSpec
  -> KubernetesWorkloadWire
  -> Either String ()
validateWorkloadWire expected observed = do
  let coordinate = internalWorkloadObject expected
      metadata = wireWorkloadMetadata observed
      spec = wireWorkloadSpec observed
      podSpec = wirePodTemplateSpec (wireSpecTemplate spec)
      status = wireWorkloadStatus observed
      expectedKind = case internalKubernetesKind coordinate of
        RecoveryPlaneDeployment -> "Deployment"
        RecoveryPlaneStatefulSet -> "StatefulSet"
        _ -> ""
      containerNames = map wireContainerName (wirePodContainers podSpec)
  requireEqual "apiVersion" "apps/v1" (wireWorkloadApiVersion observed)
  requireEqual "kind" expectedKind (wireWorkloadKind observed)
  validateMetadata coordinate True metadata
  requireEqual "spec.replicas" 1 (wireSpecReplicas spec)
  requireEqual
    "spec.template.spec.serviceAccountName"
    (internalWorkloadServiceAccount expected)
    (wirePodServiceAccountName podSpec)
  requireEqual
    "spec.template.spec.containers"
    [internalWorkloadContainer expected]
    containerNames
  if internalWorkloadRequiresTargetAnnotations expected
    then validateTargetAnnotations metadata (wireSpecTemplate spec)
    else Right ()
  generation <-
    maybe
      (Left "metadata.generation is absent")
      Right
      (wireMetadataGeneration metadata)
  unless (generation > 0) (Left "metadata.generation is not positive")
  requireEqual
    "status.observedGeneration"
    generation
    (wireStatusObservedGeneration status)
  requireEqual "status.replicas" 1 (wireStatusReplicas status)
  requireEqual "status.readyReplicas" 1 (wireStatusReadyReplicas status)
  requireEqual "status.updatedReplicas" 1 (wireStatusUpdatedReplicas status)
  case internalKubernetesKind coordinate of
    RecoveryPlaneDeployment -> do
      requireEqual
        "spec.strategy.type"
        (Just (KubernetesStrategyWire "Recreate"))
        (wireSpecStrategy spec)
      validateDeploymentStatus status
    RecoveryPlaneStatefulSet -> validateStatefulSetStatus status
    _ -> Left "closed workload table contains a non-workload kind"

validateDeploymentStatus
  :: KubernetesWorkloadStatusWire -> Either String ()
validateDeploymentStatus status = do
  requireEqual "status.availableReplicas" (Just 1) (wireStatusAvailableReplicas status)
  let available =
        [ condition
        | condition <- wireStatusConditions status
        , wireConditionType condition == "Available"
        ]
  requireEqual
    "status.conditions[Available]"
    [KubernetesConditionWire "Available" "True"]
    available

validateStatefulSetStatus
  :: KubernetesWorkloadStatusWire -> Either String ()
validateStatefulSetStatus status = do
  current <-
    maybe (Left "status.currentRevision is absent") Right (wireStatusCurrentRevision status)
  updated <-
    maybe (Left "status.updateRevision is absent") Right (wireStatusUpdateRevision status)
  unless (validBoundedText 253 current) (Left "status.currentRevision is invalid")
  requireEqual "status.currentRevision/updateRevision" current updated

validateTargetAnnotations
  :: KubernetesMetadataWire
  -> KubernetesPodTemplateWire
  -> Either String ()
validateTargetAnnotations metadata template =
  mapM_ validateKey targetAnnotationKeys
 where
  validateKey key = do
    observed <-
      maybe
        (Left ("metadata.annotations is missing " ++ Text.unpack key))
        Right
        (Map.lookup key (wireMetadataAnnotations metadata))
    templateObserved <-
      maybe
        (Left ("spec.template.metadata.annotations is missing " ++ Text.unpack key))
        Right
        (Map.lookup key (wireTemplateAnnotations (wirePodTemplateMetadata template)))
    unless
      (validBoundedText 512 observed)
      (Left ("metadata annotation is invalid: " ++ Text.unpack key))
    requireEqual
      ("metadata/template annotation " ++ Text.unpack key)
      observed
      templateObserved

targetAnnotationKeys :: [Text]
targetAnnotationKeys =
  [ "prodbox.io/target-agent-identity"
  , "prodbox.io/target-agent-rollout-digest"
  ]

validateMetadata
  :: RecoveryPlaneKubernetesObject
  -> Bool
  -> KubernetesMetadataWire
  -> Either String ()
validateMetadata expected requireGeneration metadata = do
  requireEqual "metadata.name" (internalKubernetesName expected) (wireMetadataName metadata)
  requireEqual
    "metadata.namespace"
    (internalKubernetesNamespace expected)
    (wireMetadataNamespace metadata)
  unless
    (validBoundedText 128 (wireMetadataUid metadata))
    (Left "metadata.uid is absent, malformed, or exceeds its bound")
  if requireGeneration && not (isJust (wireMetadataGeneration metadata))
    then Left "metadata.generation is absent"
    else Right ()

validBoundedText :: Int -> Text -> Bool
validBoundedText maximumLength value =
  not (Text.null value)
    && Text.length value <= maximumLength
    && Text.all
      (\character -> character >= ' ' && character <= '~')
      value

requireEqual :: (Eq value, Show value) => String -> value -> value -> Either String ()
requireEqual label expected actual =
  unless
    (actual == expected)
    ( Left
        ( label
            ++ " mismatch: expected "
            ++ show expected
            ++ ", observed "
            ++ show actual
        )
    )

data KubernetesServiceAccountWire = KubernetesServiceAccountWire
  { wireServiceAccountApiVersion :: !Text
  , wireServiceAccountKind :: !Text
  , wireServiceAccountMetadata :: !KubernetesMetadataWire
  , wireServiceAccountAutomount :: !(Maybe Bool)
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesServiceAccountWire where
  parseJSON = withObject "Kubernetes ServiceAccount" $ \value ->
    KubernetesServiceAccountWire
      <$> value .: "apiVersion"
      <*> value .: "kind"
      <*> value .: "metadata"
      <*> value .:? "automountServiceAccountToken"

data KubernetesPolicyRuleWire = KubernetesPolicyRuleWire
  { wireRuleApiGroups :: ![Text]
  , wireRuleResources :: ![Text]
  , wireRuleResourceNames :: ![Text]
  , wireRuleVerbs :: ![Text]
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesPolicyRuleWire where
  parseJSON = withObject "Kubernetes policy rule" $ \value ->
    KubernetesPolicyRuleWire
      <$> value .: "apiGroups"
      <*> value .: "resources"
      <*> value .: "resourceNames"
      <*> value .: "verbs"

data KubernetesRoleWire = KubernetesRoleWire
  { wireRoleApiVersion :: !Text
  , wireRoleKind :: !Text
  , wireRoleMetadata :: !KubernetesMetadataWire
  , wireRoleRules :: ![KubernetesPolicyRuleWire]
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesRoleWire where
  parseJSON = withObject "Kubernetes Role" $ \value ->
    KubernetesRoleWire
      <$> value .: "apiVersion"
      <*> value .: "kind"
      <*> value .: "metadata"
      <*> value .: "rules"

data KubernetesRoleRefWire = KubernetesRoleRefWire
  { wireRoleRefApiGroup :: !Text
  , wireRoleRefKind :: !Text
  , wireRoleRefName :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesRoleRefWire where
  parseJSON = withObject "Kubernetes roleRef" $ \value ->
    KubernetesRoleRefWire
      <$> value .: "apiGroup"
      <*> value .: "kind"
      <*> value .: "name"

data KubernetesSubjectWire = KubernetesSubjectWire
  { wireSubjectKind :: !Text
  , wireSubjectName :: !Text
  , wireSubjectNamespace :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesSubjectWire where
  parseJSON = withObject "Kubernetes subject" $ \value ->
    KubernetesSubjectWire
      <$> value .: "kind"
      <*> value .: "name"
      <*> value .:? "namespace"

data KubernetesRoleBindingWire = KubernetesRoleBindingWire
  { wireRoleBindingApiVersion :: !Text
  , wireRoleBindingKind :: !Text
  , wireRoleBindingMetadata :: !KubernetesMetadataWire
  , wireRoleBindingRoleRef :: !KubernetesRoleRefWire
  , wireRoleBindingSubjects :: ![KubernetesSubjectWire]
  }
  deriving stock (Eq, Show)

instance FromJSON KubernetesRoleBindingWire where
  parseJSON = withObject "Kubernetes RoleBinding" $ \value ->
    KubernetesRoleBindingWire
      <$> value .: "apiVersion"
      <*> value .: "kind"
      <*> value .: "metadata"
      <*> value .: "roleRef"
      <*> value .: "subjects"

validateBootstrapCaller
  :: ByteString -> ByteString -> ByteString -> Either String ()
validateBootstrapCaller serviceAccountBytes roleBytes bindingBytes = do
  serviceAccount <- eitherDecodeStrict' serviceAccountBytes
  role <- eitherDecodeStrict' roleBytes
  binding <- eitherDecodeStrict' bindingBytes
  validateBootstrapCallerServiceAccount serviceAccount
  validateBootstrapCallerRole role
  validateBootstrapCallerRoleBinding binding

validateBootstrapCallerServiceAccount
  :: KubernetesServiceAccountWire -> Either String ()
validateBootstrapCallerServiceAccount observed = do
  requireEqual "ServiceAccount apiVersion" "v1" (wireServiceAccountApiVersion observed)
  requireEqual "ServiceAccount kind" "ServiceAccount" (wireServiceAccountKind observed)
  validateMetadata bootstrapCallerServiceAccount False (wireServiceAccountMetadata observed)
  requireEqual
    "ServiceAccount automountServiceAccountToken"
    (Just False)
    (wireServiceAccountAutomount observed)

validateBootstrapCallerRole :: KubernetesRoleWire -> Either String ()
validateBootstrapCallerRole observed = do
  requireEqual "Role apiVersion" "rbac.authorization.k8s.io/v1" (wireRoleApiVersion observed)
  requireEqual "Role kind" "Role" (wireRoleKind observed)
  validateMetadata bootstrapCallerRole False (wireRoleMetadata observed)
  requireEqual
    "Role rules"
    [ KubernetesPolicyRuleWire
        [""]
        ["serviceaccounts/token"]
        [bootstrapCallerName]
        ["create"]
    ]
    (wireRoleRules observed)

validateBootstrapCallerRoleBinding
  :: KubernetesRoleBindingWire -> Either String ()
validateBootstrapCallerRoleBinding observed = do
  requireEqual
    "RoleBinding apiVersion"
    "rbac.authorization.k8s.io/v1"
    (wireRoleBindingApiVersion observed)
  requireEqual "RoleBinding kind" "RoleBinding" (wireRoleBindingKind observed)
  validateMetadata bootstrapCallerRoleBinding False (wireRoleBindingMetadata observed)
  requireEqual
    "RoleBinding roleRef"
    ( KubernetesRoleRefWire
        "rbac.authorization.k8s.io"
        "Role"
        bootstrapCallerGrantName
    )
    (wireRoleBindingRoleRef observed)
  requireEqual
    "RoleBinding subjects"
    [ KubernetesSubjectWire
        "ServiceAccount"
        bootstrapCallerName
        (Just bootstrapBrokerNamespace)
    ]
    (wireRoleBindingSubjects observed)

kubernetesObjectPath :: RecoveryPlaneKubernetesObject -> String
kubernetesObjectPath coordinate =
  let namespace = Text.unpack (internalKubernetesNamespace coordinate)
      name = Text.unpack (internalKubernetesName coordinate)
   in case internalKubernetesKind coordinate of
        RecoveryPlaneDeployment ->
          "/apis/apps/v1/namespaces/" ++ namespace ++ "/deployments/" ++ name
        RecoveryPlaneStatefulSet ->
          "/apis/apps/v1/namespaces/" ++ namespace ++ "/statefulsets/" ++ name
        RecoveryPlaneServiceAccount ->
          "/api/v1/namespaces/" ++ namespace ++ "/serviceaccounts/" ++ name
        RecoveryPlaneRole ->
          "/apis/rbac.authorization.k8s.io/v1/namespaces/"
            ++ namespace
            ++ "/roles/"
            ++ name
        RecoveryPlaneRoleBinding ->
          "/apis/rbac.authorization.k8s.io/v1/namespaces/"
            ++ namespace
            ++ "/rolebindings/"
            ++ name

renderKubernetesObject :: RecoveryPlaneKubernetesObject -> Text
renderKubernetesObject coordinate =
  Text.pack (show (internalKubernetesKind coordinate))
    <> "/"
    <> internalKubernetesNamespace coordinate
    <> "/"
    <> internalKubernetesName coordinate

minioWorkload :: RecoveryPlaneWorkloadSpec
minioWorkload =
  statefulSetSpec ComponentMinio "prodbox" "minio" "minio" "minio"

vaultWorkload :: RecoveryPlaneWorkloadSpec
vaultWorkload =
  statefulSetSpec ComponentVaultWorkload "vault" "vault" "vault" "vault"

bootstrapBrokerWorkload :: RecoveryPlaneWorkloadSpec
bootstrapBrokerWorkload =
  deploymentSpec
    ComponentChartBootstrapBroker
    bootstrapBrokerNamespace
    "bootstrap-broker"
    (brokerStaticServiceAccount brokerChartStatics)
    "bootstrap-broker"

lifecycleAuthorityWorkload :: RecoveryPlaneWorkloadSpec
lifecycleAuthorityWorkload =
  statefulSetSpec
    ComponentChartLifecycleAuthority
    "lifecycle-authority"
    "lifecycle-authority"
    ( lifecycleAuthorityStaticServiceAccount
        lifecycleAuthorityChartStatics
    )
    "lifecycle-authority"

authorityBackupWorkload :: RecoveryPlaneWorkloadSpec
authorityBackupWorkload =
  deploymentSpec
    ComponentChartAuthorityBackup
    "authority-backup"
    "authority-backup"
    (authorityBackupStaticServiceAccount authorityBackupChartStatics)
    "authority-backup"

providerWorkerWorkload :: RecoveryPlaneWorkloadSpec
providerWorkerWorkload =
  deploymentSpec
    ComponentChartProviderWorker
    "provider-worker"
    "provider-worker"
    (providerWorkerStaticServiceAccount providerWorkerChartStatics)
    "provider-worker"

targetSecretAgentWorkload :: RecoveryPlaneWorkloadSpec
targetSecretAgentWorkload =
  deploymentSpec
    ComponentChartTargetSecretAgent
    "target-secret-agent"
    "target-secret-agent"
    (targetSecretAgentStaticServiceAccount targetSecretAgentChartStatics)
    "target-secret-agent"

statefulSetSpec
  :: ComponentId -> Text -> Text -> Text -> Text -> RecoveryPlaneWorkloadSpec
statefulSetSpec component namespace name serviceAccount container =
  RecoveryPlaneWorkloadSpec
    component
    (RecoveryPlaneKubernetesObject RecoveryPlaneStatefulSet namespace name)
    serviceAccount
    container
    False

deploymentSpec
  :: ComponentId -> Text -> Text -> Text -> Text -> RecoveryPlaneWorkloadSpec
deploymentSpec component namespace name serviceAccount container =
  RecoveryPlaneWorkloadSpec
    component
    (RecoveryPlaneKubernetesObject RecoveryPlaneDeployment namespace name)
    serviceAccount
    container
    (component == ComponentChartTargetSecretAgent)

bootstrapBrokerNamespace :: Text
bootstrapBrokerNamespace = "bootstrap-broker"

bootstrapCallerName :: Text
bootstrapCallerName =
  brokerStaticCleanupCallerServiceAccount brokerChartStatics

bootstrapCallerGrantName :: Text
bootstrapCallerGrantName = bootstrapCallerName <> "-self-tokenrequest"

bootstrapCallerServiceAccount :: RecoveryPlaneKubernetesObject
bootstrapCallerServiceAccount =
  RecoveryPlaneKubernetesObject
    RecoveryPlaneServiceAccount
    bootstrapBrokerNamespace
    bootstrapCallerName

bootstrapCallerRole :: RecoveryPlaneKubernetesObject
bootstrapCallerRole =
  RecoveryPlaneKubernetesObject
    RecoveryPlaneRole
    bootstrapBrokerNamespace
    bootstrapCallerGrantName

bootstrapCallerRoleBinding :: RecoveryPlaneKubernetesObject
bootstrapCallerRoleBinding =
  RecoveryPlaneKubernetesObject
    RecoveryPlaneRoleBinding
    bootstrapBrokerNamespace
    bootstrapCallerGrantName

closedWorkloadSpecs :: [RecoveryPlaneWorkloadSpec]
closedWorkloadSpecs =
  [ minioWorkload
  , vaultWorkload
  , bootstrapBrokerWorkload
  , lifecycleAuthorityWorkload
  , authorityBackupWorkload
  , providerWorkerWorkload
  , targetSecretAgentWorkload
  ]

data RecoveryPlaneComponentObserverRegression
  = RecoveryPlaneComponentObserverRegressionInternal
  { internalRegressionClosedInventory :: !Bool
  , internalRegressionReadyRowsExact :: !Bool
  , internalRegressionMissingRefused :: !Bool
  , internalRegressionMalformedRefused :: !Bool
  , internalRegressionUnauthorizedRefused :: !Bool
  , internalRegressionPartialRolloutRefused :: !Bool
  , internalRegressionInvalidUidRefused :: !Bool
  , internalRegressionGenerationMismatchRefused :: !Bool
  , internalRegressionConditionMismatchRefused :: !Bool
  , internalRegressionVaultSealedRefused :: !Bool
  , internalRegressionNetworkUnknownRefused :: !Bool
  , internalRegressionExternalCallerExact :: !Bool
  , internalRegressionOpacityClosed :: !Bool
  }

fixedRecoveryPlaneComponentObserverRegression
  :: RecoveryPlaneComponentObserverRegression
fixedRecoveryPlaneComponentObserverRegression =
  RecoveryPlaneComponentObserverRegressionInternal
    { internalRegressionClosedInventory = closedInventoryRegression
    , internalRegressionReadyRowsExact = readyRowsRegression
    , internalRegressionMissingRefused =
        classifyWorkloadObservation minioWorkload RecoveryPlaneKubernetesMissing
          == RecoveryPlaneRawMissing "RecoveryPlaneStatefulSet/prodbox/minio"
    , internalRegressionMalformedRefused =
        isPartial
          ( classifyWorkloadObservation
              minioWorkload
              (RecoveryPlaneKubernetesFound "not-json")
          )
    , internalRegressionUnauthorizedRefused =
        isUnavailable
          ( classifyWorkloadObservation
              minioWorkload
              (RecoveryPlaneKubernetesUnauthorized 403)
          )
    , internalRegressionPartialRolloutRefused =
        isPartial
          ( classifyWorkloadObservation
              minioWorkload
              (RecoveryPlaneKubernetesFound (fixtureWorkloadBytes minioWorkload FixtureNotReady))
          )
    , internalRegressionInvalidUidRefused =
        isPartial
          ( classifyWorkloadObservation
              minioWorkload
              (RecoveryPlaneKubernetesFound (fixtureWorkloadBytes minioWorkload FixtureInvalidUid))
          )
    , internalRegressionGenerationMismatchRefused =
        isPartial
          ( classifyWorkloadObservation
              minioWorkload
              (RecoveryPlaneKubernetesFound (fixtureWorkloadBytes minioWorkload FixtureWrongGeneration))
          )
    , internalRegressionConditionMismatchRefused =
        isPartial
          ( classifyWorkloadObservation
              providerWorkerWorkload
              (RecoveryPlaneKubernetesFound (fixtureWorkloadBytes providerWorkerWorkload FixtureWrongCondition))
          )
    , internalRegressionVaultSealedRefused =
        isPartial
          ( classifyVaultObservation
              (RecoveryPlaneVaultObserved (SealStatus True True 3 5 0))
          )
    , internalRegressionNetworkUnknownRefused =
        isUnobservable
          ( classifyWorkloadObservation
              minioWorkload
              (RecoveryPlaneKubernetesUnobservable "network unknown")
          )
    , internalRegressionExternalCallerExact = externalCallerRegression
    , internalRegressionOpacityClosed = True
    }

recoveryPlaneComponentObserverClosedInventory
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverClosedInventory = internalRegressionClosedInventory

recoveryPlaneComponentObserverReadyRowsExact
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverReadyRowsExact = internalRegressionReadyRowsExact

recoveryPlaneComponentObserverMissingRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverMissingRefused = internalRegressionMissingRefused

recoveryPlaneComponentObserverMalformedRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverMalformedRefused = internalRegressionMalformedRefused

recoveryPlaneComponentObserverUnauthorizedRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverUnauthorizedRefused = internalRegressionUnauthorizedRefused

recoveryPlaneComponentObserverPartialRolloutRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverPartialRolloutRefused = internalRegressionPartialRolloutRefused

recoveryPlaneComponentObserverInvalidUidRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverInvalidUidRefused = internalRegressionInvalidUidRefused

recoveryPlaneComponentObserverGenerationMismatchRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverGenerationMismatchRefused = internalRegressionGenerationMismatchRefused

recoveryPlaneComponentObserverConditionMismatchRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverConditionMismatchRefused = internalRegressionConditionMismatchRefused

recoveryPlaneComponentObserverVaultSealedRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverVaultSealedRefused = internalRegressionVaultSealedRefused

recoveryPlaneComponentObserverNetworkUnknownRefused
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverNetworkUnknownRefused = internalRegressionNetworkUnknownRefused

recoveryPlaneComponentObserverExternalCallerExact
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverExternalCallerExact = internalRegressionExternalCallerExact

recoveryPlaneComponentObserverOpacityClosed
  :: RecoveryPlaneComponentObserverRegression -> Bool
recoveryPlaneComponentObserverOpacityClosed = internalRegressionOpacityClosed

closedInventoryRegression :: Bool
closedInventoryRegression =
  sort (map internalWorkloadComponent closedWorkloadSpecs)
    == sort
      [ ComponentMinio
      , ComponentVaultWorkload
      , ComponentChartBootstrapBroker
      , ComponentChartLifecycleAuthority
      , ComponentChartAuthorityBackup
      , ComponentChartProviderWorker
      , ComponentChartTargetSecretAgent
      ]
    && length (nub (map internalWorkloadObject closedWorkloadSpecs))
      == length closedWorkloadSpecs

readyRowsRegression :: Bool
readyRowsRegression =
  all
    ( \spec ->
        classifyWorkloadObservation
          spec
          (RecoveryPlaneKubernetesFound (fixtureWorkloadBytes spec FixtureReady))
          == RecoveryPlaneRawReady
    )
    closedWorkloadSpecs
    && classifyVaultObservation
      (RecoveryPlaneVaultObserved (SealStatus True False 3 5 0))
      == RecoveryPlaneRawReady

externalCallerRegression :: Bool
externalCallerRegression =
  classifyBootstrapCallerObservations
    (RecoveryPlaneKubernetesFound fixtureCallerServiceAccountBytes)
    (RecoveryPlaneKubernetesFound fixtureCallerRoleBytes)
    (RecoveryPlaneKubernetesFound fixtureCallerRoleBindingBytes)
    == RecoveryPlaneRawReady
    && isPartial
      ( classifyBootstrapCallerObservations
          (RecoveryPlaneKubernetesFound fixtureCallerServiceAccountBytes)
          (RecoveryPlaneKubernetesFound fixtureCallerRoleBytes)
          ( RecoveryPlaneKubernetesFound
              (fixtureCallerRoleBindingBytesWithSubject "wrong-caller")
          )
      )

data FixtureWorkloadState
  = FixtureReady
  | FixtureNotReady
  | FixtureInvalidUid
  | FixtureWrongGeneration
  | FixtureWrongCondition
  deriving stock (Eq, Show)

fixtureWorkloadBytes
  :: RecoveryPlaneWorkloadSpec -> FixtureWorkloadState -> ByteString
fixtureWorkloadBytes expected state =
  LazyByteString.toStrict
    ( Aeson.encode
        ( object
            [ "apiVersion" .= ("apps/v1" :: Text)
            , "kind" .= expectedKind
            , "metadata"
                .= object
                  [ "name" .= internalKubernetesName coordinate
                  , "namespace" .= internalKubernetesNamespace coordinate
                  , "uid" .= fixtureUid
                  , "generation" .= (7 :: Int)
                  , "annotations" .= fixtureAnnotations
                  ]
            , "spec"
                .= object
                  ( [ "replicas" .= (1 :: Int)
                    , "template"
                        .= object
                          [ "metadata"
                              .= object ["annotations" .= fixtureAnnotations]
                          , "spec"
                              .= object
                                [ "serviceAccountName"
                                    .= internalWorkloadServiceAccount expected
                                , "containers"
                                    .= [ object
                                           [ "name"
                                               .= internalWorkloadContainer expected
                                           ]
                                       ]
                                ]
                          ]
                    ]
                      ++ [ "strategy" .= object ["type" .= ("Recreate" :: Text)]
                         | internalKubernetesKind coordinate
                             == RecoveryPlaneDeployment
                         ]
                  )
            , "status" .= fixtureStatus
            ]
        )
    )
 where
  coordinate = internalWorkloadObject expected
  expectedKind = case internalKubernetesKind coordinate of
    RecoveryPlaneDeployment -> "Deployment" :: Text
    RecoveryPlaneStatefulSet -> "StatefulSet"
    _ -> "Invalid"
  fixtureUid :: Text
  fixtureUid = case state of
    FixtureInvalidUid -> ""
    _ -> "12345678-1234-1234-1234-123456789abc"
  observedGeneration = case state of
    FixtureWrongGeneration -> 6 :: Int
    _ -> 7
  fixtureAnnotations :: Map Text Text
  fixtureAnnotations
    | internalWorkloadRequiresTargetAnnotations expected =
        Map.fromList
          [ ("prodbox.io/target-agent-identity", "target-fixture")
          , ("prodbox.io/target-agent-rollout-digest", "digest-fixture")
          ]
    | otherwise = Map.empty
  readyReplicas = case state of
    FixtureNotReady -> 0 :: Int
    _ -> 1
  fixtureStatus = case internalKubernetesKind coordinate of
    RecoveryPlaneDeployment ->
      object
        [ "observedGeneration" .= observedGeneration
        , "replicas" .= (1 :: Int)
        , "readyReplicas" .= readyReplicas
        , "updatedReplicas" .= (1 :: Int)
        , "availableReplicas" .= readyReplicas
        , "conditions"
            .= [ object
                   [ "type" .= ("Available" :: Text)
                   , "status"
                       .= if state == FixtureWrongCondition
                         then ("False" :: Text)
                         else "True"
                   ]
               ]
        ]
    RecoveryPlaneStatefulSet ->
      object
        [ "observedGeneration" .= observedGeneration
        , "replicas" .= (1 :: Int)
        , "readyReplicas" .= readyReplicas
        , "updatedReplicas" .= (1 :: Int)
        , "currentRevision" .= ("revision-7" :: Text)
        , "updateRevision" .= ("revision-7" :: Text)
        ]
    _ -> object []

fixtureCallerServiceAccountBytes :: ByteString
fixtureCallerServiceAccountBytes =
  encodeStrict
    ( object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ServiceAccount" :: Text)
        , "metadata" .= fixtureCallerMetadata bootstrapCallerName
        , "automountServiceAccountToken" .= False
        ]
    )

fixtureCallerRoleBytes :: ByteString
fixtureCallerRoleBytes =
  encodeStrict
    ( object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("Role" :: Text)
        , "metadata" .= fixtureCallerMetadata bootstrapCallerGrantName
        , "rules"
            .= [ object
                   [ "apiGroups" .= ([""] :: [Text])
                   , "resources" .= (["serviceaccounts/token"] :: [Text])
                   , "resourceNames" .= [bootstrapCallerName]
                   , "verbs" .= (["create"] :: [Text])
                   ]
               ]
        ]
    )

fixtureCallerRoleBindingBytes :: ByteString
fixtureCallerRoleBindingBytes =
  fixtureCallerRoleBindingBytesWithSubject bootstrapCallerName

fixtureCallerRoleBindingBytesWithSubject :: Text -> ByteString
fixtureCallerRoleBindingBytesWithSubject subjectName =
  encodeStrict
    ( object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("RoleBinding" :: Text)
        , "metadata" .= fixtureCallerMetadata bootstrapCallerGrantName
        , "roleRef"
            .= object
              [ "apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
              , "kind" .= ("Role" :: Text)
              , "name" .= bootstrapCallerGrantName
              ]
        , "subjects"
            .= [ object
                   [ "kind" .= ("ServiceAccount" :: Text)
                   , "name" .= subjectName
                   , "namespace" .= bootstrapBrokerNamespace
                   ]
               ]
        ]
    )

fixtureCallerMetadata :: Text -> Value
fixtureCallerMetadata name =
  object
    [ "name" .= name
    , "namespace" .= bootstrapBrokerNamespace
    , "uid" .= ("12345678-1234-1234-1234-123456789abc" :: Text)
    ]

encodeStrict :: Value -> ByteString
encodeStrict = LazyByteString.toStrict . Aeson.encode

isPartial :: RecoveryPlaneRawComponentResult -> Bool
isPartial result = case result of
  RecoveryPlaneRawPartial _ -> True
  _ -> False

isUnavailable :: RecoveryPlaneRawComponentResult -> Bool
isUnavailable result = case result of
  RecoveryPlaneRawUnavailable _ -> True
  _ -> False

isUnobservable :: RecoveryPlaneRawComponentResult -> Bool
isUnobservable result = case result of
  RecoveryPlaneRawUnobservable _ -> True
  _ -> False
