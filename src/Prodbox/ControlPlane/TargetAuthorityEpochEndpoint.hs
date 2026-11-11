{-# LANGUAGE OverloadedStrings #-}

-- | Staging interception after request authentication and replay admission.
module Prodbox.ControlPlane.TargetAuthorityEpochEndpoint
  ( targetEpochVerifiedHandler
  , targetEpochSignedObservationHandler
  , isTargetEpochObservationForRole
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneResponse)
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , VerifiedControlPlaneRequest
  , verifiedRequestBody
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (TargetSecretTrustInstall))
import Prodbox.ControlPlane.TargetAuthenticatedResponse
  ( TargetAuthenticatedResponseError (TargetResponseRequestRefused)
  , signTargetAuthenticatedResponse
  )
import Prodbox.ControlPlane.TargetAuthorityEpochExecution
import Prodbox.ControlPlane.TargetAuthorityEpochProtocol
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( TargetAuthorityTrustRequest (..)
  , TargetAuthorityTrustResponse (..)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution (TargetAgentIdentity)
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

targetEpochVerifiedHandler
  :: (Monad m)
  => Int
  -> TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (ReplyStatus, ByteString))
targetEpochVerifiedHandler maximumBytes localAgent interpreter verified
  | verifiedRequestRoute verified /= TargetSecretTrustInstall = pure Nothing
  | otherwise = case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict (verifiedRequestBody verified)) of
      Left _ -> pure Nothing
      Right (TargetAuthorityTrustRequest bytes)
        | not (isTargetEpochRequest bytes) -> pure Nothing
        | otherwise -> Just . renderResponse <$> handle bytes
 where
  handle bytes = case decodeTargetEpochRequest bytes of
    Left _ -> pure (TargetAuthorityTrustRefusedResponse "epoch-staging/request-codec-rejected")
    Right request -> do
      result <- case request of
        TargetEpochMutate action -> fmap TargetEpochMutated <$> executeTargetAuthorityEpoch localAgent interpreter verified action
        TargetEpochObserve target ->
          fmap (TargetEpochObserved target)
            <$> observeTargetAuthorityEpoch localAgent interpreter verified target
      pure $ case result of
        Left err -> executionFailure err
        Right response -> case encodeTargetEpochResponse response of
          Left _ -> TargetAuthorityTrustUnavailableResponse "epoch-staging/response-invalid"
          Right encoded -> TargetAuthorityEpochResponse encoded

-- | Opt-in composition for an authenticated observation. It does not alter
-- the existing route or replay policy; its caller must keep the original
-- deadline over observation, signing, and delivery and admit the larger wire.
targetEpochSignedObservationHandler
  :: (Monad m)
  => Int
  -> Int
  -> TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> RequestSigningCapability m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (Either TargetAuthenticatedResponseError ByteString))
targetEpochSignedObservationHandler maximumRequest maximumResponse localAgent interpreter signer verified
  | not
      ( isTargetEpochObservationForRole
          maximumRequest
          TargetSecretAgentRuntime
          (verifiedRequestRoute verified)
          (verifiedRequestBody verified)
      ) =
      pure Nothing
  | otherwise = do
      handled <- targetEpochVerifiedHandler maximumRequest localAgent interpreter verified
      case handled of
        Nothing -> pure (Just (Left TargetResponseRequestRefused))
        Just (status, body) ->
          Just
            <$> signTargetAuthenticatedResponse
              maximumResponse
              localAgent
              signer
              verified
              (fromIntegral (replyStatusCode status))
              body

renderResponse :: TargetAuthorityTrustResponse -> (ReplyStatus, ByteString)
renderResponse response =
  (status, LazyByteString.toStrict (encodeControlPlaneResponse response))
 where
  status = case response of
    TargetAuthorityTrustInstalledResponse _ -> ReplyOk
    TargetAuthorityTrustAlreadyInstalledResponse _ -> ReplyOk
    TargetAuthorityTrustRecoveredResponse _ -> ReplyOk
    TargetAuthorityTrustRefusedResponse _ -> ReplyConflict
    TargetAuthorityTrustUnavailableResponse _ -> ReplyServiceUnavailable
    TargetAuthorityEpochResponse _ -> ReplyOk

executionFailure :: TargetEpochExecutionError -> TargetAuthorityTrustResponse
executionFailure err = constructor ("epoch-staging/" <> renderTargetEpochExecutionError err)
 where
  constructor = case err of
    TargetEpochClockUnavailable -> TargetAuthorityTrustUnavailableResponse
    TargetEpochPublishedEpochUnavailable -> TargetAuthorityTrustUnavailableResponse
    TargetEpochIssuerUnavailable -> TargetAuthorityTrustUnavailableResponse
    TargetEpochEffectTimedOut -> TargetAuthorityTrustUnavailableResponse
    TargetEpochStoreFailed _ -> TargetAuthorityTrustUnavailableResponse
    TargetEpochRecordCodecFailed _ -> TargetAuthorityTrustUnavailableResponse
    TargetEpochRequestBindingInvalid -> TargetAuthorityTrustRefusedResponse
    TargetEpochLocalAgentMismatch -> TargetAuthorityTrustRefusedResponse
    TargetEpochIssuerMismatch -> TargetAuthorityTrustRefusedResponse
    TargetEpochRequestEpochChanged -> TargetAuthorityTrustRefusedResponse
    TargetEpochExecutionDeadlineReached -> TargetAuthorityTrustRefusedResponse
    TargetEpochTransitionRefused _ -> TargetAuthorityTrustRefusedResponse
    TargetEpochReadBackChanged -> TargetAuthorityTrustRefusedResponse

isTargetEpochObservationForRole :: Int -> RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isTargetEpochObservationForRole maximumBytes role route body =
  role == TargetSecretAgentRuntime
    && route == TargetSecretTrustInstall
    && isObservation body
 where
  isObservation bytes = case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict bytes) of
    Left _ -> False
    Right (TargetAuthorityTrustRequest inner) -> case decodeTargetEpochRequest inner of
      Right (TargetEpochObserve _) -> True
      Right (TargetEpochMutate _) -> False
      Left _ -> False
