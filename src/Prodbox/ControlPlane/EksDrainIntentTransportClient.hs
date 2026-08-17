{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated transport binding for the Lifecycle Authority EKS
-- drain-intent endpoint.  The route is role-indexed, and every successful wire
-- response is reconstructed through the exact opaque committed-proof check.
module Prodbox.ControlPlane.EksDrainIntentTransportClient
  ( lifecycleAuthorityEksDrainIntentAuthenticatedClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleEksDrainIntentRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClient (..)
  , EksDrainIntentClientError (..)
  )
import Prodbox.ControlPlane.EksDrainIntentEndpoint
  ( EksDrainIntentConfirmationKind (..)
  , EksDrainIntentEndpointResponseError (..)
  , confirmEksDrainIntentEndpointResponse
  , confirmEksDrainIntentRecoveryResponse
  , decodeEksDrainIntentEndpointResponse
  , eksDrainIntentCommitWireRequest
  , eksDrainIntentReadBackWireRequest
  , eksDrainIntentRecoveryWireRequest
  , eksDrainIntentWireResponseStatus
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

lifecycleAuthorityEksDrainIntentAuthenticatedClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> EksDrainIntentClient IO
lifecycleAuthorityEksDrainIntentAuthenticatedClient transport =
  EksDrainIntentClient
    { commitAndReadBackEksDrainIntent = \intent ->
        callEndpoint
          intent
          EksDrainIntentCommitConfirmed
          (eksDrainIntentCommitWireRequest intent)
    , readBackCommittedEksDrainIntent = \intent ->
        callEndpoint
          intent
          EksDrainIntentReadBackConfirmed
          (eksDrainIntentReadBackWireRequest intent)
    , recoverCommittedEksDrainIntent = \identity ->
        callRecoveryEndpoint
          identity
          (eksDrainIntentRecoveryWireRequest identity)
    }
 where
  callEndpoint intent expectedKind request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleEksDrainIntentRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first EksDrainIntentClientTransportFailed attempted
      response <-
        first
          EksDrainIntentClientResponseInvalid
          (decodeEksDrainIntentEndpointResponse body)
      let expectedStatus = replyStatusCode (eksDrainIntentWireResponseStatus response)
      if status == expectedStatus
        then
          first
            endpointResponseError
            (confirmEksDrainIntentEndpointResponse expectedKind intent response)
        else
          Left
            ( EksDrainIntentClientHttpStatusMismatch
                expectedStatus
                status
            )

  callRecoveryEndpoint identity request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleEksDrainIntentRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first EksDrainIntentClientTransportFailed attempted
      response <-
        first
          EksDrainIntentClientResponseInvalid
          (decodeEksDrainIntentEndpointResponse body)
      let expectedStatus = replyStatusCode (eksDrainIntentWireResponseStatus response)
      if status == expectedStatus
        then
          first
            endpointResponseError
            (confirmEksDrainIntentRecoveryResponse identity response)
        else
          Left
            ( EksDrainIntentClientHttpStatusMismatch
                expectedStatus
                status
            )

endpointResponseError
  :: EksDrainIntentEndpointResponseError -> EksDrainIntentClientError
endpointResponseError err = case err of
  EksDrainIntentEndpointResponseRefused refusal ->
    EksDrainIntentClientRemoteRefused (Text.pack (show refusal))
  EksDrainIntentEndpointResponseUnavailable unavailable ->
    EksDrainIntentClientRemoteUnavailable (Text.pack (show unavailable))
  EksDrainIntentEndpointResponseVersionMismatch {} -> invalidProof
  EksDrainIntentEndpointResponseKindMismatch {} -> invalidProof
  EksDrainIntentEndpointResponseDigestMismatch {} -> invalidProof
  EksDrainIntentEndpointResponseProofInvalid {} -> invalidProof
  EksDrainIntentEndpointResponseRecoveryIdentityMismatch {} -> invalidProof
 where
  invalidProof = EksDrainIntentClientRemoteProofInvalid (Text.pack (show err))
