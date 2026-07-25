{-# LANGUAGE ImportQualifiedPost #-}

-- | Production gateway-backed Model-B compare-and-swap adapter for retained
-- lease, intent, SMTP projection, and fenced Pulumi checkpoint objects.
-- Coordinates carry the retained control-plane endpoint explicitly; this
-- module never consults an ambient kube context or selected target sink.
--
-- Sprint 4.51 Increment B (Stage B): the Model-B ↔ authority-object translation
-- (coordinate-authority guard, payload encode/decode, observation/response
-- mapping) is lifted into the shared 'Prodbox.Lifecycle.ModelBCasTransport'.
-- This adapter is now the thin GATEWAY transport: it delegates to
-- 'modelBCasAdapterOverTransport' over the gateway daemon's authority-object HTTP
-- routes, so it can never drift from the host-direct transport
-- ('Prodbox.Lifecycle.HostDirectAuthorityStore.hostDirectModelBCasAdapter'), which
-- delegates to the same shared adapter.
module Prodbox.Lifecycle.CheckpointAuthorityStore
  ( ModelBCodec (..)
  , gatewayModelBCasAdapter
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.ObjectStore
  ( AuthorityObjectCasRequest (..)
  , AuthorityObjectCasResponse
  , AuthorityObjectObservation
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter
  , ModelBCodec (..)
  , checkpointAuthorityGatewayEndpoint
  )
import Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  )

-- | The gateway daemon object-store transport is polymorphic in the storage
-- lifetime it carries: it validates the coordinate's authority and logical name
-- only, so it serves any lifetime the caller demands. (Sprint 4.51 Stage D
-- retypes this to @'ChartLifetime@ once the retained coordinates move host-direct.)
gatewayModelBCasAdapter
  :: LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter l IO value
gatewayModelBCasAdapter authority codec =
  modelBCasAdapterOverTransport authority (gatewayTransport authority) codec

-- | The gateway HTTP transport: authority-object reads and conditional writes go
-- to the retained control-plane endpoint over the daemon's authority-object
-- routes. Rendered gateway errors are normalised to 'Text' exactly as the
-- pre-Stage-B adapter did, so the shared adapter's 'ModelBUnobservable' /
-- 'ModelBCasUnobservable' mappings are byte-identical.
gatewayTransport :: LongLivedCheckpointAuthority -> ModelBTransport
gatewayTransport authority =
  ModelBTransport
    { transportObserveObject = gatewayObserveObject endpoint
    , transportCasObject = gatewayCasObject endpoint
    }
 where
  endpoint = Text.unpack (checkpointAuthorityGatewayEndpoint authority)

gatewayObserveObject
  :: String -> Text -> IO (Either Text AuthorityObjectObservation)
gatewayObserveObject endpoint logicalName =
  mapGatewayError <$> GatewayClient.getAuthorityObject endpoint logicalName

gatewayCasObject
  :: String -> AuthorityObjectCasRequest -> IO (Either Text AuthorityObjectCasResponse)
gatewayCasObject endpoint request =
  case authorityObjectCasLeaseGuard request of
    Nothing ->
      mapGatewayError
        <$> GatewayClient.compareAndSwapAuthorityObject
          endpoint
          (authorityObjectCasLogicalName request)
          (authorityObjectCasExpectedVersion request)
          (authorityObjectCasPayload request)
    Just guard ->
      mapGatewayError
        <$> GatewayClient.compareAndSwapAuthorityObjectGuarded
          endpoint
          (authorityObjectCasLogicalName request)
          (authorityObjectCasExpectedVersion request)
          guard
          (authorityObjectCasPayload request)

mapGatewayError :: Either GatewayClient.GatewayError a -> Either Text a
mapGatewayError = first (Text.pack . GatewayClient.renderGatewayError)
