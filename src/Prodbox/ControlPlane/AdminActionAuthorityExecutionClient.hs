{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Typed authenticated client for the Runner-only Lifecycle Authority Admin
-- Action execution route.  Endpoint, operation identity, and Pod identity are
-- projected from the same signed permit; callers select only one closed
-- command and cannot supply a free-form Authority path.
module Prodbox.ControlPlane.AdminActionAuthorityExecutionClient
  ( AdminActionAuthorityExecutionClientError (..)
  , callObserveAdminLegacyMigration
  , callPublishAdminLegacyMigration
  , callConfirmAdminLegacySourceAbsent
  , callObserveAdminQuotaJournal
  , callAdvanceAdminQuotaJournal
  , callRecordAdminQuotaProviderResponse
  , callCommitAdminActionCompletion
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityCommand (..)
  , AdminActionAuthorityRequest (..)
  , AdminActionAuthorityResponse
  , adminActionAuthorityExecutionResponseMaximumBytes
  , adminActionAuthorityExecutionResponseStatus
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
  , ControlPlaneRouteFor (LifecycleAdminActionExecutionRoute)
  , mkLifecycleAuthorityEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Http.Client (defaultHttpConfig)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionReceipt
  , SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionPermitAuthorityEndpoint
  , adminActionPermitOperationId
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  )
import Prodbox.Lifecycle.AdminAction.QuotaJournal
  ( QuotaExternalObservation
  )

data AdminActionAuthorityExecutionClientError
  = AdminActionAuthorityEndpointMissing
  | AdminActionAuthorityEndpointInvalid !ControlPlaneClientError
  | AdminActionAuthorityTransportFailed !AuthenticatedClientError
  | AdminActionAuthorityResponseInvalid !ControlPlaneResponseCodecError
  | AdminActionAuthorityHttpStatusMismatch !Int !Int
  deriving stock (Eq, Show)

callObserveAdminLegacyMigration
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callObserveAdminLegacyMigration bounds providers permit =
  callAdminAuthority bounds providers permit ObserveAdminLegacyMigration

callPublishAdminLegacyMigration
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> ByteString
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callPublishAdminLegacyMigration bounds providers permit sourceBytes =
  callAdminAuthority bounds providers permit (PublishAdminLegacyMigration sourceBytes)

callConfirmAdminLegacySourceAbsent
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> Text
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callConfirmAdminLegacySourceAbsent bounds providers permit evidence =
  callAdminAuthority bounds providers permit (ConfirmAdminLegacySourceAbsent evidence)

callObserveAdminQuotaJournal
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callObserveAdminQuotaJournal bounds providers permit =
  callAdminAuthority bounds providers permit ObserveAdminQuotaJournal

callAdvanceAdminQuotaJournal
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> [QuotaExternalObservation]
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callAdvanceAdminQuotaJournal bounds providers permit observations =
  callAdminAuthority bounds providers permit (AdvanceAdminQuotaJournal observations)

callRecordAdminQuotaProviderResponse
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> Text
  -> Text
  -> Text
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callRecordAdminQuotaProviderResponse bounds providers permit attempt provider status =
  callAdminAuthority
    bounds
    providers
    permit
    (RecordAdminQuotaProviderResponse attempt provider status)

callCommitAdminActionCompletion
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> AdminActionReceipt
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callCommitAdminActionCompletion bounds providers permit receipt =
  callAdminAuthority bounds providers permit (CommitAdminActionCompletion receipt)

callAdminAuthority
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> SignedAdminActionPermit
  -> AdminActionAuthorityCommand
  -> IO (Either AdminActionAuthorityExecutionClientError AdminActionAuthorityResponse)
callAdminAuthority bounds providers permit command =
  case authorityEndpoint permit of
    Left err -> pure (Left err)
    Right endpointText ->
      case do
        endpoint <-
          first AdminActionAuthorityEndpointInvalid (mkLifecycleAuthorityEndpoint endpointText)
        first
          AdminActionAuthorityEndpointInvalid
          ( newControlPlaneClient
              defaultHttpConfig
              adminActionAuthorityExecutionResponseMaximumBytes
              endpoint
          ) of
        Left err -> pure (Left err)
        Right client -> do
          attempted <-
            callAuthenticatedControlPlane
              bounds
              providers
              client
              LifecycleAdminActionExecutionRoute
              ( LazyByteString.toStrict
                  (encodeControlPlaneRequest (requestFor permit command))
              )
          pure $ do
            ControlPlaneResponse status body <-
              first AdminActionAuthorityTransportFailed attempted
            decoded <-
              first
                AdminActionAuthorityResponseInvalid
                ( decodeControlPlaneResponse
                    adminActionAuthorityExecutionResponseMaximumBytes
                    (LazyByteString.fromStrict body)
                )
            let expected = adminActionAuthorityExecutionResponseStatus decoded
            if status == expected
              then Right decoded
              else Left (AdminActionAuthorityHttpStatusMismatch expected status)

requestFor
  :: SignedAdminActionPermit
  -> AdminActionAuthorityCommand
  -> AdminActionAuthorityRequest
requestFor permit command =
  AdminActionAuthorityRequest
    { adminAuthorityRequestPermit = permit
    , adminAuthorityRequestOperationId = adminActionPermitOperationId core
    , adminAuthorityRequestPodName = adminActionJobPodName binding
    , adminAuthorityRequestPodUid = adminActionJobPodUid binding
    , adminAuthorityRequestCommand = command
    }
 where
  core = signedAdminActionPermitCore permit
  binding = signedAdminActionPermitBinding permit

authorityEndpoint
  :: SignedAdminActionPermit
  -> Either AdminActionAuthorityExecutionClientError Text
authorityEndpoint permit =
  Right
    ( adminActionPermitAuthorityEndpoint
        (signedAdminActionPermitCore permit)
    )
