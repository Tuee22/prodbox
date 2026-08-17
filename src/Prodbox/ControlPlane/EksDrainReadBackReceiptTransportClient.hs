{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated transport implementation of the closed EKS drain
-- read-back receipt client.  Successful responses are never trusted as raw
-- booleans: the canonical retained intent and receipt bytes remint the opaque
-- absence proof locally after exact identity and digest validation.
module Prodbox.ControlPlane.EksDrainReadBackReceiptTransportClient
  ( lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleEksDrainReadBackReceiptRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  , encodeEksDrainIntentAuthorityIdentity
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
  ( EksDrainReadBackReceiptClient (..)
  , EksDrainReadBackReceiptClientError (..)
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptEndpoint
  ( EksDrainReadBackReceiptConfirmationKind (..)
  , EksDrainReadBackReceiptEndpointResponseError (..)
  , EksDrainReadBackReceiptWireAction (EksDrainReadBackReceiptWireCommit)
  , EksDrainReadBackReceiptWireRefusal
    ( EksDrainReadBackReceiptWireReceiptMissing
    )
  , EksDrainReadBackReceiptWireRequest (..)
  , confirmEksDrainReadBackReceiptEndpointResponse
  , confirmEksDrainReadBackReceiptIdentityResponse
  , confirmEksDrainReadBackReceiptRecoveryResponse
  , decodeEksDrainReadBackReceiptEndpointResponse
  , eksDrainReadBackReceiptCommitWireRequest
  , eksDrainReadBackReceiptEndpointFormatVersion
  , eksDrainReadBackReceiptReadBackWireRequest
  , eksDrainReadBackReceiptRecoveryWireRequest
  , eksDrainReadBackReceiptWireResponseStatus
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> EksDrainReadBackReceiptClient IO
lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient transport =
  EksDrainReadBackReceiptClient
    { commitAndReadBackEksDrainReceipt = \committed attempt observation ->
        case eksDrainReadBackReceiptCommitWireRequest
          committed
          attempt
          observation of
          Left err ->
            pure (Left (EksDrainReadBackReceiptClientReceiptFailed err))
          Right request ->
            callExpectedEndpoint
              committed
              EksDrainReadBackReceiptCommitConfirmed
              request
    , readBackEksDrainReceipt = \committed ->
        callExpectedEndpoint
          committed
          EksDrainReadBackReceiptReadBackConfirmed
          (eksDrainReadBackReceiptReadBackWireRequest committed)
    , commitCanonicalEksDrainReceiptFromIntentIdentity = \identity bytes ->
        callIdentityEndpoint
          identity
          EksDrainReadBackReceiptCommitConfirmed
          (canonicalCommitRequest identity bytes)
    , recoverEksDrainReceiptFromIntentIdentity = \identity ->
        callRecoveryEndpoint
          identity
          (eksDrainReadBackReceiptRecoveryWireRequest identity)
    }
 where
  callExpectedEndpoint committed expectedKind request = do
    response <- callWire request
    pure $ do
      wire <- response
      first
        endpointResponseError
        ( confirmEksDrainReadBackReceiptEndpointResponse
            expectedKind
            committed
            wire
        )

  callIdentityEndpoint identity expectedKind request = do
    response <- callWire request
    pure $ do
      wire <- response
      first
        endpointResponseError
        ( confirmEksDrainReadBackReceiptIdentityResponse
            expectedKind
            identity
            wire
        )

  callRecoveryEndpoint identity request = do
    response <- callWire request
    pure $ do
      wire <- response
      first
        endpointResponseError
        (confirmEksDrainReadBackReceiptRecoveryResponse identity wire)

  callWire request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleEksDrainReadBackReceiptRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first EksDrainReadBackReceiptClientTransportFailed attempted
      response <-
        first
          EksDrainReadBackReceiptClientResponseInvalid
          (decodeEksDrainReadBackReceiptEndpointResponse body)
      let expectedStatus =
            replyStatusCode
              (eksDrainReadBackReceiptWireResponseStatus response)
      if status == expectedStatus
        then Right response
        else
          Left
            ( EksDrainReadBackReceiptClientHttpStatusMismatch
                expectedStatus
                status
            )

canonicalCommitRequest
  :: EksDrainIntentAuthorityIdentity
  -> ByteString
  -> EksDrainReadBackReceiptWireRequest
canonicalCommitRequest identity bytes =
  EksDrainReadBackReceiptWireRequest
    { eksDrainReadBackReceiptWireRequestVersion =
        eksDrainReadBackReceiptEndpointFormatVersion
    , eksDrainReadBackReceiptWireRequestAction =
        EksDrainReadBackReceiptWireCommit
    , eksDrainReadBackReceiptWireRequestIntentIdentityBytes =
        encodeEksDrainIntentAuthorityIdentity identity
    , eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes = bytes
    }

endpointResponseError
  :: EksDrainReadBackReceiptEndpointResponseError
  -> EksDrainReadBackReceiptClientError
endpointResponseError err = case err of
  EksDrainReadBackReceiptEndpointResponseRefused
    EksDrainReadBackReceiptWireReceiptMissing ->
      EksDrainReadBackReceiptClientRecoveryMissing
  EksDrainReadBackReceiptEndpointResponseRefused refusal ->
    EksDrainReadBackReceiptClientRemoteRefused (Text.pack (show refusal))
  EksDrainReadBackReceiptEndpointResponseUnavailable reason ->
    EksDrainReadBackReceiptClientRemoteUnavailable (Text.pack (show reason))
  _ -> EksDrainReadBackReceiptClientRemoteProofInvalid (Text.pack (show err))
