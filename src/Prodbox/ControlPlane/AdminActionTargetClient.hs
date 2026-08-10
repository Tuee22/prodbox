{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client for the two permit-scoped Admin Action Target lanes.
-- Construction takes the endpoint only from the signed plan member and derives
-- operation and Pod identity from the same permit, so those bindings cannot
-- drift into caller-selected request fields.
module Prodbox.ControlPlane.AdminActionTargetClient
  ( AdminActionTargetClientError (..)
  , callAdminTargetGenerationTombstone
  , callAdminCustodyTombstone
  )
where

import Codec.Serialise qualified as Codec
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AdminActionTargetEndpoint
  ( AdminCustodyTombstoneRequest (..)
  , AdminCustodyTombstoneResponse
  , AdminTargetTombstoneRequest (..)
  , AdminTargetTombstoneResponse
  , adminActionTargetResponseMaximumBytes
  , adminCustodyTombstoneResponseStatus
  , adminTargetTombstoneResponseStatus
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedTransportBounds
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClientError
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( TargetSecretAdminActionCustodyTombstoneRoute
    , TargetSecretAdminActionGenerationTombstoneRoute
    )
  , mkTargetSecretAgentEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Http.Client (defaultHttpConfig)
import Prodbox.Http.ReplyStatus (ReplyStatus, replyStatusCode)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminRetainedCustodyMember (..)
  , AdminTargetGeneration (..)
  , SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionPermitOperationId
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( RetainedCustodyTombstoneAction
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneAction
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

data AdminActionTargetClientError
  = AdminActionTargetEndpointInvalid !ControlPlaneClientError
  | AdminActionTargetTransportFailed !AuthenticatedClientError
  | AdminActionTargetResponseInvalid !ControlPlaneResponseCodecError
  | AdminActionTargetHttpStatusMismatch !Int !Int
  deriving stock (Eq, Show)

callAdminTargetGenerationTombstone
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> AdminTargetGeneration
  -> TargetGenerationTombstoneAction
  -> IO (Either AdminActionTargetClientError AdminTargetTombstoneResponse)
callAdminTargetGenerationTombstone bounds providers permit member action =
  callTarget
    bounds
    providers
    (adminTargetGenerationEndpoint member)
    TargetSecretAdminActionGenerationTombstoneRoute
    ( AdminTargetTombstoneRequest
        { adminTargetRequestPermit = permit
        , adminTargetRequestOperationId = operationId
        , adminTargetRequestPodName = podName
        , adminTargetRequestPodUid = podUid
        , adminTargetRequestMember = member
        , adminTargetRequestAction = action
        }
    )
    adminTargetTombstoneResponseStatus
 where
  core = signedAdminActionPermitCore permit
  binding = signedAdminActionPermitBinding permit
  operationId = adminActionPermitOperationId core
  podName = adminActionJobPodName binding
  podUid = adminActionJobPodUid binding

callAdminCustodyTombstone
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> AdminRetainedCustodyMember
  -> RetainedCustodyTombstoneAction
  -> IO (Either AdminActionTargetClientError AdminCustodyTombstoneResponse)
callAdminCustodyTombstone bounds providers permit member action =
  callTarget
    bounds
    providers
    (adminRetainedCustodyEndpoint member)
    TargetSecretAdminActionCustodyTombstoneRoute
    ( AdminCustodyTombstoneRequest
        { adminCustodyRequestPermit = permit
        , adminCustodyRequestOperationId = operationId
        , adminCustodyRequestPodName = podName
        , adminCustodyRequestPodUid = podUid
        , adminCustodyRequestMember = member
        , adminCustodyRequestAction = action
        }
    )
    adminCustodyTombstoneResponseStatus
 where
  core = signedAdminActionPermitCore permit
  binding = signedAdminActionPermitBinding permit
  operationId = adminActionPermitOperationId core
  podName = adminActionJobPodName binding
  podUid = adminActionJobPodUid binding

callTarget
  :: (Codec.Serialise request, Codec.Serialise response)
  => AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> Text
  -> ControlPlaneRouteFor 'TargetSecretAgentRuntime
  -> request
  -> (response -> ReplyStatus)
  -> IO (Either AdminActionTargetClientError response)
callTarget bounds providers endpointText route request responseStatus =
  case do
    endpoint <- first AdminActionTargetEndpointInvalid (mkTargetSecretAgentEndpoint endpointText)
    first
      AdminActionTargetEndpointInvalid
      (newControlPlaneClient defaultHttpConfig adminActionTargetResponseMaximumBytes endpoint) of
    Left err -> pure (Left err)
    Right client -> do
      attempted <-
        callAuthenticatedControlPlane
          bounds
          providers
          client
          route
          (LazyByteString.toStrict (encodeControlPlaneRequest request))
      pure $ do
        ControlPlaneResponse status body <- first AdminActionTargetTransportFailed attempted
        decoded <-
          first
            AdminActionTargetResponseInvalid
            ( decodeControlPlaneResponse
                adminActionTargetResponseMaximumBytes
                (LazyByteString.fromStrict body)
            )
        let expected = responseStatus decoded
        if status == replyStatusCode expected
          then Right decoded
          else
            Left
              ( AdminActionTargetHttpStatusMismatch
                  (replyStatusCode expected)
                  status
              )
