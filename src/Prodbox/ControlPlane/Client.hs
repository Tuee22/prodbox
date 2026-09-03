{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Role-indexed client boundary for the five physically separate lifecycle
-- control-plane services.
--
-- A 'ControlPlaneRouteFor role' can be used only with a
-- 'ControlPlaneClient role'.  The route constructors are closed and carry no
-- free-form path, so a Lifecycle Authority client cannot call a Target Secret
-- Agent, Provider Worker, backup, or TLS route.  The production constructor
-- reuses the process-wide HTTP manager and applies one response-size ceiling;
-- the injected constructor keeps the boundary deterministic in unit tests.
module Prodbox.ControlPlane.Client
  ( ControlPlaneEndpoint
  , mkLifecycleAuthorityEndpoint
  , mkProviderWorkerEndpoint
  , mkAuthorityBackupEndpoint
  , mkTlsRetentionEndpoint
  , mkTargetSecretAgentEndpoint
  , controlPlaneEndpointText
  , ControlPlaneRouteFor (..)
  , controlPlaneRouteForValue
  , ControlPlaneResponse (..)
  , ControlPlaneClientError (..)
  , ControlPlaneTransport
  , ControlPlaneClient
  , newControlPlaneClient
  , controlPlaneClientWithTransport
  , callControlPlane
  )
where

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Method (Method)
import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlaneGet, ControlPlanePost)
  , ControlPlaneRoute (..)
  , controlPlaneRouteMethod
  , controlPlaneRoutePath
  )
import Prodbox.Http.Client
  ( HttpBoundedError (..)
  , HttpConfig
  , HttpError
  , httpRequestRawBounded
  )
import Prodbox.Runtime.Role (RuntimeRole (..))

-- | A validated base URL indexed by its one physical runtime role.  The
-- constructor is private; the five named smart constructors are the only way
-- to select the phantom role.
newtype ControlPlaneEndpoint (r :: RuntimeRole) = ControlPlaneEndpoint Text
  deriving (Eq, Show)

data ControlPlaneClientError
  = ControlPlaneEndpointEmpty
  | ControlPlaneEndpointContainsWhitespace
  | ControlPlaneEndpointContainsControl
  | ControlPlaneEndpointTooLong !Int !Int
  | ControlPlaneEndpointSchemeUnsupported
  | ControlPlaneEndpointAuthorityInvalid
  | ControlPlaneResponseLimitMustBePositive
  | ControlPlaneTransportFailed !HttpError
  | ControlPlaneResponseTooLarge !Int !Int
  deriving (Eq, Show)

mkLifecycleAuthorityEndpoint
  :: Text
  -> Either ControlPlaneClientError (ControlPlaneEndpoint 'LifecycleAuthorityRuntime)
mkLifecycleAuthorityEndpoint = mkControlPlaneEndpoint

mkProviderWorkerEndpoint
  :: Text
  -> Either ControlPlaneClientError (ControlPlaneEndpoint 'ProviderWorkerRuntime)
mkProviderWorkerEndpoint = mkControlPlaneEndpoint

mkAuthorityBackupEndpoint
  :: Text
  -> Either ControlPlaneClientError (ControlPlaneEndpoint 'AuthorityBackupRuntime)
mkAuthorityBackupEndpoint = mkControlPlaneEndpoint

mkTlsRetentionEndpoint
  :: Text
  -> Either ControlPlaneClientError (ControlPlaneEndpoint 'TlsRetentionRuntime)
mkTlsRetentionEndpoint = mkControlPlaneEndpoint

mkTargetSecretAgentEndpoint
  :: Text
  -> Either ControlPlaneClientError (ControlPlaneEndpoint 'TargetSecretAgentRuntime)
mkTargetSecretAgentEndpoint = mkControlPlaneEndpoint

mkControlPlaneEndpoint
  :: Text -> Either ControlPlaneClientError (ControlPlaneEndpoint r)
mkControlPlaneEndpoint raw
  | Text.null raw = Left ControlPlaneEndpointEmpty
  | Text.any isControl raw = Left ControlPlaneEndpointContainsControl
  | Text.any isSpace raw = Left ControlPlaneEndpointContainsWhitespace
  | Text.length raw > maximumEndpointLength =
      Left (ControlPlaneEndpointTooLong (Text.length raw) maximumEndpointLength)
  | otherwise = case endpointAuthority raw of
      Nothing -> Left ControlPlaneEndpointSchemeUnsupported
      Just authority
        | Text.null authority -> Left ControlPlaneEndpointAuthorityInvalid
        | Text.any isForbiddenAuthorityCharacter authority ->
            Left ControlPlaneEndpointAuthorityInvalid
        | otherwise -> Right (ControlPlaneEndpoint (Text.dropWhileEnd (== '/') raw))
 where
  maximumEndpointLength = 2048
  endpointAuthority endpoint =
    Text.dropWhileEnd (== '/')
      <$> (Text.stripPrefix "http://" endpoint <|> Text.stripPrefix "https://" endpoint)
  isForbiddenAuthorityCharacter character =
    character == '/' || character == '?' || character == '#' || character == '@'

controlPlaneEndpointText :: ControlPlaneEndpoint r -> Text
controlPlaneEndpointText (ControlPlaneEndpoint endpoint) = endpoint

-- | The route family indexed by its owning runtime role.  There is no generic
-- constructor accepting a 'ControlPlaneRoute' or a path.
data ControlPlaneRouteFor (r :: RuntimeRole) where
  LifecycleAuthorityControlRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleMigrationApplyRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleProjectionImportRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAuthorityObserveRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAuthorityBackupExportRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAuthorityDecommissionExportRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAuthorityDecommissionStopRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleRetainedSesLeaseRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecyclePulumiCheckpointRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleOperationSubmitRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleOperationObserveRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleConfigObserveRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleConfigProposeCasRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleExternalMaterialIngressRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleFederationRegisterRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAdminActionRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAwsAdminProvisionerRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleProviderDispatchRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleTlsRetentionObserveRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleTlsRetentionPromoteRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleTlsRetentionWorkflowRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAdminActionExecutionRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleBootstrapHandoffAcceptRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleBootstrapHandoffObserveRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleTargetIntentIssueRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleRetainedMaterialDeliveryRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleCleanupRunRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleEksDrainIntentRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleEksDrainReadBackReceiptRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAwsStackReaderRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleAwsStackCreationBindingRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleOwnershipManifestRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleRecoveryPlaneRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleLocalRke2HostObservationRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleCascadeRetainedSlotRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  LifecycleControllerOwnerRoute
    :: ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  ProviderWorkApplyRoute
    :: ControlPlaneRouteFor 'ProviderWorkerRuntime
  ProviderWorkObserveRoute
    :: ControlPlaneRouteFor 'ProviderWorkerRuntime
  AuthorityBackupCopyRoute
    :: ControlPlaneRouteFor 'AuthorityBackupRuntime
  AuthorityBackupObserveRoute
    :: ControlPlaneRouteFor 'AuthorityBackupRuntime
  TlsRetentionStoreRoute
    :: ControlPlaneRouteFor 'TlsRetentionRuntime
  TlsRetentionRestoreRoute
    :: ControlPlaneRouteFor 'TlsRetentionRuntime
  TargetMaterialObserveRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetSecretDecommissionInventoryRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetSecretDecommissionTombstoneRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetSecretDecommissionCustodyTombstoneRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetTlsPrepareExchangeRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetTlsRetainRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetTlsHomeWrapRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetTlsHomeRewrapRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetTlsRestoreRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetTlsVerifySourceRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetSecretAdminActionGenerationTombstoneRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetSecretAdminActionCustodyTombstoneRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetChildCustodyCommitRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetChildRecoveryPrepareRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetChildRecoveryObserveRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetSecretTrustInstallRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime
  TargetRetainedMaterialRewrapRoute
    :: ControlPlaneRouteFor 'TargetSecretAgentRuntime

deriving instance Eq (ControlPlaneRouteFor r)
deriving instance Show (ControlPlaneRouteFor r)

controlPlaneRouteForValue :: ControlPlaneRouteFor r -> ControlPlaneRoute
controlPlaneRouteForValue route = case route of
  LifecycleAuthorityControlRoute -> LifecycleAuthorityControl
  LifecycleMigrationApplyRoute -> LifecycleMigrationApply
  LifecycleProjectionImportRoute -> LifecycleProjectionImport
  LifecycleAuthorityObserveRoute -> LifecycleAuthorityObserve
  LifecycleAuthorityBackupExportRoute -> LifecycleAuthorityBackupExport
  LifecycleAuthorityDecommissionExportRoute -> LifecycleAuthorityDecommissionExport
  LifecycleAuthorityDecommissionStopRoute -> LifecycleAuthorityDecommissionStop
  LifecycleRetainedSesLeaseRoute -> LifecycleRetainedSesLease
  LifecyclePulumiCheckpointRoute -> LifecyclePulumiCheckpoint
  LifecycleOperationSubmitRoute -> LifecycleOperationSubmit
  LifecycleOperationObserveRoute -> LifecycleOperationObserve
  LifecycleConfigObserveRoute -> LifecycleConfigObserve
  LifecycleConfigProposeCasRoute -> LifecycleConfigProposeCas
  LifecycleExternalMaterialIngressRoute -> LifecycleExternalMaterialIngress
  LifecycleFederationRegisterRoute -> LifecycleFederationRegister
  LifecycleAdminActionRoute -> LifecycleAdminAction
  LifecycleAwsAdminProvisionerRoute -> LifecycleAwsAdminProvisioner
  LifecycleProviderDispatchRoute -> LifecycleProviderDispatch
  LifecycleTlsRetentionObserveRoute -> LifecycleTlsRetentionObserve
  LifecycleTlsRetentionPromoteRoute -> LifecycleTlsRetentionPromote
  LifecycleTlsRetentionWorkflowRoute -> LifecycleTlsRetentionWorkflow
  LifecycleAdminActionExecutionRoute -> LifecycleAdminActionExecution
  LifecycleBootstrapHandoffAcceptRoute -> LifecycleBootstrapHandoffAccept
  LifecycleBootstrapHandoffObserveRoute -> LifecycleBootstrapHandoffObserve
  LifecycleTargetIntentIssueRoute -> LifecycleTargetIntentIssue
  LifecycleRetainedMaterialDeliveryRoute -> LifecycleRetainedMaterialDelivery
  LifecycleCleanupRunRoute -> LifecycleCleanupRun
  LifecycleEksDrainIntentRoute -> LifecycleEksDrainIntent
  LifecycleEksDrainReadBackReceiptRoute -> LifecycleEksDrainReadBackReceipt
  LifecycleAwsStackReaderRoute -> LifecycleAwsStackReader
  LifecycleAwsStackCreationBindingRoute -> LifecycleAwsStackCreationBinding
  LifecycleOwnershipManifestRoute -> LifecycleOwnershipManifest
  LifecycleRecoveryPlaneRoute -> LifecycleRecoveryPlane
  LifecycleLocalRke2HostObservationRoute -> LifecycleLocalRke2HostObservation
  LifecycleCascadeRetainedSlotRoute -> LifecycleCascadeRetainedSlot
  LifecycleControllerOwnerRoute -> LifecycleControllerOwner
  ProviderWorkApplyRoute -> ProviderWorkApply
  ProviderWorkObserveRoute -> ProviderWorkObserve
  AuthorityBackupCopyRoute -> AuthorityBackupCopy
  AuthorityBackupObserveRoute -> AuthorityBackupObserve
  TlsRetentionStoreRoute -> TlsRetentionStore
  TlsRetentionRestoreRoute -> TlsRetentionRestore
  TargetMaterialObserveRoute -> TargetMaterialObserve
  TargetSecretDecommissionInventoryRoute -> TargetSecretDecommissionInventory
  TargetSecretDecommissionTombstoneRoute -> TargetSecretDecommissionTombstone
  TargetSecretDecommissionCustodyTombstoneRoute ->
    TargetSecretDecommissionCustodyTombstone
  TargetTlsPrepareExchangeRoute -> TargetTlsPrepareExchange
  TargetTlsRetainRoute -> TargetTlsRetain
  TargetTlsHomeWrapRoute -> TargetTlsHomeWrap
  TargetTlsHomeRewrapRoute -> TargetTlsHomeRewrap
  TargetTlsRestoreRoute -> TargetTlsRestore
  TargetTlsVerifySourceRoute -> TargetTlsVerifySource
  TargetSecretAdminActionGenerationTombstoneRoute ->
    TargetSecretAdminActionGenerationTombstone
  TargetSecretAdminActionCustodyTombstoneRoute ->
    TargetSecretAdminActionCustodyTombstone
  TargetChildCustodyCommitRoute -> TargetChildCustodyCommit
  TargetChildRecoveryPrepareRoute -> TargetChildRecoveryPrepare
  TargetChildRecoveryObserveRoute -> TargetChildRecoveryObserve
  TargetSecretTrustInstallRoute -> TargetSecretTrustInstall
  TargetRetainedMaterialRewrapRoute -> TargetRetainedMaterialRewrap

data ControlPlaneResponse = ControlPlaneResponse
  { controlPlaneResponseStatus :: !Int
  , controlPlaneResponseBody :: !ByteString
  }
  deriving (Eq, Show)

-- | Injectable byte transport.  The method and URL are already projected from
-- the indexed route and endpoint.  The production value sends canonical-CBOR
-- bytes with an explicit content type through 'httpRequestRaw'.
type ControlPlaneTransport =
  Method
  -> [Header]
  -> String
  -> ByteString
  -> IO (Either HttpBoundedError (Int, ByteString))

data ControlPlaneClient (r :: RuntimeRole) = ControlPlaneClient
  { clientEndpoint :: !(ControlPlaneEndpoint r)
  , clientMaximumResponseBytes :: !Int
  , clientTransport :: !ControlPlaneTransport
  }

newControlPlaneClient
  :: HttpConfig
  -> Int
  -> ControlPlaneEndpoint r
  -> Either ControlPlaneClientError (ControlPlaneClient r)
newControlPlaneClient httpConfig maximumResponseBytes endpoint =
  controlPlaneClientWithTransport maximumResponseBytes endpoint transport
 where
  transport method headers url body =
    httpRequestRawBounded
      httpConfig
      maximumResponseBytes
      method
      headers
      url
      (Just (LazyByteString.fromStrict body))

controlPlaneClientWithTransport
  :: Int
  -> ControlPlaneEndpoint r
  -> ControlPlaneTransport
  -> Either ControlPlaneClientError (ControlPlaneClient r)
controlPlaneClientWithTransport maximumResponseBytes endpoint transport
  | maximumResponseBytes <= 0 = Left ControlPlaneResponseLimitMustBePositive
  | otherwise =
      Right
        ControlPlaneClient
          { clientEndpoint = endpoint
          , clientMaximumResponseBytes = maximumResponseBytes
          , clientTransport = transport
          }

callControlPlane
  :: ControlPlaneClient r
  -> ControlPlaneRouteFor r
  -> ByteString
  -> IO (Either ControlPlaneClientError ControlPlaneResponse)
callControlPlane client indexedRoute body = do
  attempted <-
    clientTransport
      client
      (routeMethod route)
      [("Content-Type", "application/cbor"), ("Accept", "application/octet-stream")]
      (routeUrl (clientEndpoint client) route)
      body
  pure $ case attempted of
    Left (HttpBoundedTransport err) -> Left (ControlPlaneTransportFailed err)
    Left (HttpBoundedResponseTooLarge observed maximumAllowed) ->
      Left (ControlPlaneResponseTooLarge observed maximumAllowed)
    Right (status, responseBody)
      | ByteString.length responseBody > clientMaximumResponseBytes client ->
          Left
            ( ControlPlaneResponseTooLarge
                (ByteString.length responseBody)
                (clientMaximumResponseBytes client)
            )
      | otherwise -> Right (ControlPlaneResponse status responseBody)
 where
  route = controlPlaneRouteForValue indexedRoute

routeMethod :: ControlPlaneRoute -> Method
routeMethod route = case controlPlaneRouteMethod route of
  ControlPlaneGet -> "GET"
  ControlPlanePost -> "POST"

routeUrl :: ControlPlaneEndpoint r -> ControlPlaneRoute -> String
routeUrl endpoint route =
  Text.unpack (controlPlaneEndpointText endpoint) ++ controlPlaneRoutePath route
