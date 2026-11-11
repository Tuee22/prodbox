{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Authenticated client with exact operation/context readback checks.
module Prodbox.ControlPlane.TargetAuthorityEpochClient
  ( TargetEpochClient
  , TargetEpochClientError (..)
  , targetEpochClient
  , targetEpochClientWithin
  , decodeTargetEpochClientResponse
  , mutateTargetAuthorityEpoch
  , observeTargetAuthorityEpochWithClient
  , observeTargetAuthorityEpochWithVerifiedResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , authenticatedClientTransportWithin
  , callAuthenticatedClientTransport
  , callAuthenticatedTargetTransportWithSignedRequest
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetSecretTrustInstallRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.RequestAuthentication (TrustedRequestKey)
import Prodbox.ControlPlane.TargetAuthenticatedResponse
  ( TargetAuthenticatedResponseError
  , verifyTargetAuthenticatedResponse
  )
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetAuthorityEpochExecution
  ( TargetEpochMutationResult (..)
  , TargetEpochObservation
  )
import Prodbox.ControlPlane.TargetAuthorityEpochProtocol
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( TargetAuthorityTrustRequest (..)
  , TargetAuthorityTrustResponse (..)
  , targetAuthorityTrustResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution (TargetAgentIdentity, acceptedTargetId)
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype TargetEpochClient m = TargetEpochClient
  { callTargetEpochClient :: TargetEpochRequest -> m (Either TargetEpochClientError TargetEpochResponse)
  }

data TargetEpochClientError
  = TargetEpochClientTransportFailed !AuthenticatedClientError
  | TargetEpochClientOuterResponseInvalid !Int !ControlPlaneResponseCodecError
  | TargetEpochClientProtocolInvalid !TargetEpochProtocolError
  | TargetEpochClientHttpStatus !Int
  | TargetEpochClientRefused !Text
  | TargetEpochClientUnavailable !Text
  | TargetEpochClientReadBackMismatch
  | TargetEpochClientResponseAuthenticationFailed !TargetAuthenticatedResponseError
  deriving stock (Eq, Show)

targetEpochClient :: AuthenticatedClientTransport 'TargetSecretAgentRuntime -> TargetEpochClient IO
targetEpochClient transport = TargetEpochClient call
 where
  call request = case encodeTargetEpochRequest request of
    Left err -> pure (Left (TargetEpochClientProtocolInvalid err))
    Right encoded -> do
      result <-
        callAuthenticatedClientTransport
          transport
          TargetSecretTrustInstallRoute
          (LazyByteString.toStrict (encodeControlPlaneRequest (TargetAuthorityTrustRequest encoded)))
      pure $ first TargetEpochClientTransportFailed result >>= decodeTargetEpochClientResponse request

targetEpochClientWithin
  :: AuthorityTime -> AuthenticatedClientTransport 'TargetSecretAgentRuntime -> TargetEpochClient IO
targetEpochClientWithin deadline = targetEpochClient . authenticatedClientTransportWithin deadline

decodeTargetEpochClientResponse
  :: TargetEpochRequest -> ControlPlaneResponse -> Either TargetEpochClientError TargetEpochResponse
decodeTargetEpochClientResponse request (ControlPlaneResponse status body) = do
  response <-
    first
      (TargetEpochClientOuterResponseInvalid status)
      (decodeControlPlaneResponse targetAuthorityTrustResponseMaximumBytes (LazyByteString.fromStrict body))
  case response of
    TargetAuthorityEpochResponse encoded
      | status /= 200 -> Left (TargetEpochClientHttpStatus status)
      | otherwise -> do
          decoded <- first TargetEpochClientProtocolInvalid (decodeTargetEpochResponse encoded)
          if responseMatches request decoded
            then pure decoded
            else Left TargetEpochClientReadBackMismatch
    TargetAuthorityTrustRefusedResponse detail -> Left (TargetEpochClientRefused detail)
    TargetAuthorityTrustUnavailableResponse detail -> Left (TargetEpochClientUnavailable detail)
    TargetAuthorityTrustInstalledResponse _ -> Left TargetEpochClientReadBackMismatch
    TargetAuthorityTrustAlreadyInstalledResponse _ -> Left TargetEpochClientReadBackMismatch
    TargetAuthorityTrustRecoveredResponse _ -> Left TargetEpochClientReadBackMismatch

responseMatches :: TargetEpochRequest -> TargetEpochResponse -> Bool
responseMatches request response = case (request, response) of
  (TargetEpochObserve target, TargetEpochObserved actual _) -> target == actual
  (TargetEpochMutate action, TargetEpochMutated result) ->
    targetEpochRecordTransition record == transition
      && targetEpochRecordTarget record == acceptedTargetId (targetEpochPreparationAuthority preparation)
   where
    record = targetEpochMutationRecord result
    (preparation, transition) = case action of
      PrepareTargetAuthorityEpoch value -> (value, TargetEpochPrepared value)
      PromoteTargetAuthorityEpoch value -> (value, TargetEpochPromoted value)
      RetireTargetAuthorityEpoch value -> (value, TargetEpochRetired value)
  (TargetEpochObserve _, TargetEpochMutated _) -> False
  (TargetEpochMutate _, TargetEpochObserved _ _) -> False

mutateTargetAuthorityEpoch
  :: (Monad m)
  => TargetEpochClient m
  -> TargetAuthorityEpochAction
  -> m (Either TargetEpochClientError TargetEpochMutationResult)
mutateTargetAuthorityEpoch client action = do
  result <- callTargetEpochClient client (TargetEpochMutate action)
  pure $ result >>= mutation
 where
  mutation response = case response of
    TargetEpochMutated value -> Right value
    TargetEpochObserved _ _ -> Left TargetEpochClientReadBackMismatch

observeTargetAuthorityEpochWithClient
  :: (Monad m)
  => TargetEpochClient m -> TargetSecretId -> m (Either TargetEpochClientError TargetEpochObservation)
observeTargetAuthorityEpochWithClient client target = do
  result <- callTargetEpochClient client (TargetEpochObserve target)
  pure $ result >>= observation
 where
  observation response = case response of
    TargetEpochObserved _ value -> Right value
    TargetEpochMutated _ -> Left TargetEpochClientReadBackMismatch

-- | Opt-in signed observation. The caller supplies a currently authenticated
-- Target key and must bound key acquisition, request, verification and use by
-- the same deadline and registry revision. The transport must admit the
-- signed-envelope response size; this function never falls back to unsigned.
observeTargetAuthorityEpochWithVerifiedResponse
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetAgentIdentity
  -> TrustedRequestKey
  -> TargetSecretId
  -> IO (Either TargetEpochClientError TargetEpochObservation)
observeTargetAuthorityEpochWithVerifiedResponse transport agent trusted target =
  case encodeTargetEpochRequest request of
    Left err -> pure (Left (TargetEpochClientProtocolInvalid err))
    Right encoded -> do
      result <-
        callAuthenticatedTargetTransportWithSignedRequest
          transport
          (LazyByteString.toStrict (encodeControlPlaneRequest (TargetAuthorityTrustRequest encoded)))
      pure $ do
        (signedRequest, ControlPlaneResponse outerStatus envelope) <-
          first TargetEpochClientTransportFailed result
        if outerStatus == 200 then pure () else Left (TargetEpochClientHttpStatus outerStatus)
        (status, response) <-
          first
            TargetEpochClientResponseAuthenticationFailed
            ( verifyTargetAuthenticatedResponse
                targetAuthorityTrustResponseMaximumBytes
                agent
                trusted
                signedRequest
                envelope
            )
        decoded <-
          decodeTargetEpochClientResponse request (ControlPlaneResponse (fromIntegral status) response)
        case decoded of
          TargetEpochObserved _ value -> Right value
          TargetEpochMutated _ -> Left TargetEpochClientReadBackMismatch
 where
  request = TargetEpochObserve target
