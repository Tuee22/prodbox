{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Caller-bound client for the Lifecycle Authority's one TLS-retention slot.
-- The constructor fixes substrate and canonical scope before a request can be
-- made; the resulting value has no generic Authority-object operation.
module Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( TlsRetentionAuthorityClient (..)
  , TlsRetentionAuthorityClientError (..)
  , TlsAuthorityPromotionOutcome (..)
  , mkTlsRetentionAuthorityClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleTlsRetentionObserveRoute
    , LifecycleTlsRetentionPromoteRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TlsRetentionAuthority
  ( TlsRetentionSlotError
  , mkTlsRetentionSlot
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
  ( TlsAuthorityObserveRequest (..)
  , TlsAuthorityPromoteRequest (..)
  , TlsAuthorityResponse (..)
  , tlsAuthorityResponseMaximumBytes
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval
  , PromotionEvidence
  , RetainedTlsRef
  , TlsRetentionState
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data TlsRetentionAuthorityClient m = TlsRetentionAuthorityClient
  { observeTlsRetentionCurrent
      :: m (Either TlsRetentionAuthorityClientError TlsRetentionState)
  , promoteTlsRetentionCurrent
      :: KeyRotationApproval
      -> PromotionEvidence
      -> RetainedTlsRef
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityPromotionOutcome
           )
  }

data TlsAuthorityPromotionOutcome
  = TlsAuthorityPromotionCommitted !TlsRetentionState
  | TlsAuthorityPromotionAlreadyCurrent !TlsRetentionState
  deriving stock (Eq, Show)

data TlsRetentionAuthorityClientError
  = TlsRetentionAuthorityClientSlotInvalid !TlsRetentionSlotError
  | TlsRetentionAuthorityClientTransportFailed !AuthenticatedClientError
  | TlsRetentionAuthorityClientResponseInvalid !ControlPlaneResponseCodecError
  | TlsRetentionAuthorityClientHttpStatus !Int
  | TlsRetentionAuthorityClientRemoteRefused !Text
  | TlsRetentionAuthorityClientUnavailable
  | TlsRetentionAuthorityClientConcurrentWrite
  | TlsRetentionAuthorityClientResponseShapeMismatch
  deriving stock (Eq, Show)

mkTlsRetentionAuthorityClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Text
  -> Text
  -> Either TlsRetentionAuthorityClientError (TlsRetentionAuthorityClient IO)
mkTlsRetentionAuthorityClient transport substrate scope = do
  _ <- first TlsRetentionAuthorityClientSlotInvalid (mkTlsRetentionSlot substrate scope)
  Right
    TlsRetentionAuthorityClient
      { observeTlsRetentionCurrent = observe
      , promoteTlsRetentionCurrent = promote
      }
 where
  observe = do
    response <-
      call
        LifecycleTlsRetentionObserveRoute
        TlsAuthorityObserveRequest
          { tlsAuthorityObserveSubstrate = substrate
          , tlsAuthorityObserveScope = scope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityObserved state -> Right state
        other -> Left (remoteError other)

  promote approval evidence candidate = do
    response <-
      call
        LifecycleTlsRetentionPromoteRoute
        TlsAuthorityPromoteRequest
          { tlsAuthorityPromoteSubstrate = substrate
          , tlsAuthorityPromoteScope = scope
          , tlsAuthorityPromoteApproval = approval
          , tlsAuthorityPromoteEvidence = evidence
          , tlsAuthorityPromoteCandidate = candidate
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityPromotionApplied state ->
          Right (TlsAuthorityPromotionCommitted state)
        TlsAuthorityPromotionNoop state ->
          Right (TlsAuthorityPromotionAlreadyCurrent state)
        other -> Left (remoteError other)

  call route request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        route
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first TlsRetentionAuthorityClientTransportFailed attempted
      response <-
        first
          TlsRetentionAuthorityClientResponseInvalid
          ( decodeControlPlaneResponse
              tlsAuthorityResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      if status == expectedStatus response
        then Right response
        else Left (TlsRetentionAuthorityClientHttpStatus status)

  expectedStatus response = case response of
    TlsAuthorityObserved _ -> 200
    TlsAuthorityPromotionApplied _ -> 200
    TlsAuthorityPromotionNoop _ -> 200
    TlsAuthorityPromotionRefused _ -> 409
    TlsAuthorityConcurrentWrite -> 409
    TlsAuthorityUnavailable -> 503
    TlsAuthorityRequestRefused -> 400

remoteError :: TlsAuthorityResponse -> TlsRetentionAuthorityClientError
remoteError response = case response of
  TlsAuthorityPromotionRefused detail ->
    TlsRetentionAuthorityClientRemoteRefused detail
  TlsAuthorityConcurrentWrite -> TlsRetentionAuthorityClientConcurrentWrite
  TlsAuthorityUnavailable -> TlsRetentionAuthorityClientUnavailable
  TlsAuthorityRequestRefused ->
    TlsRetentionAuthorityClientRemoteRefused "request-refused"
  _ -> TlsRetentionAuthorityClientResponseShapeMismatch
