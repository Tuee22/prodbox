{-# LANGUAGE OverloadedStrings #-}

-- | Staging interception after request authentication and replay admission.
module Prodbox.ControlPlane.TargetAuthorityEpochEndpoint
  ( targetEpochVerifiedHandler
  , targetEpochSignedObservationHandler
  , targetEpochNegotiatedHandler
  , targetEpochDeadlineBoundedHandler
  , isTargetEpochObservationForRole
  , isSignedTargetEpochObservationForRole
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneResponse)
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , VerifiedControlPlaneRequest
  , verifiedRequestBody
  , verifiedRequestDeadline
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
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))
import System.Timeout (timeout)

targetEpochVerifiedHandler
  :: (Monad m)
  => Int
  -> TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (ReplyStatus, ByteString))
targetEpochVerifiedHandler = targetEpochHandler False

targetEpochHandler
  :: (Monad m)
  => Bool
  -> Int
  -> TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (ReplyStatus, ByteString))
targetEpochHandler allowSigned maximumBytes localAgent interpreter verified
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
        TargetEpochObserveSigned target
          | allowSigned ->
              fmap (TargetEpochObserved target)
                <$> observeTargetAuthorityEpoch localAgent interpreter verified target
          | otherwise -> pure (Left TargetEpochRequestBindingInvalid)
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
      ( isSignedTargetEpochObservationForRole
          maximumRequest
          TargetSecretAgentRuntime
          (verifiedRequestRoute verified)
          (verifiedRequestBody verified)
      ) =
      pure Nothing
  | otherwise = do
      handled <- targetEpochHandler True maximumRequest localAgent interpreter verified
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

-- | Staged dispatch for peers which can sign. Legacy requests retain their
-- original response; a failed signature never falls back to an unsigned reply.
-- Runtime installation must still provide a trusted signer, enforce the
-- original deadline and admit the signed response and replay costs.
targetEpochNegotiatedHandler
  :: (Monad m)
  => Int
  -> Int
  -> TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> RequestSigningCapability m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (ReplyStatus, ByteString))
targetEpochNegotiatedHandler maximumRequest maximumResponse localAgent interpreter signer verified = do
  result <-
    targetEpochSignedObservationHandler
      maximumRequest
      maximumResponse
      localAgent
      interpreter
      signer
      verified
  case result of
    Nothing -> targetEpochVerifiedHandler maximumRequest localAgent interpreter verified
    Just (Left _) -> pure (Just (ReplyServiceUnavailable, "signed-observation-refused"))
    Just (Right envelope) -> pure (Just (ReplyOk, envelope))

-- | Bound the complete signed observation, including signing and the closing
-- clock observation, by the verified request's original deadline. The caller
-- supplies a local bounded clock and still owns traffic and physical identity
-- admission. Legacy requests retain their existing handler.
targetEpochDeadlineBoundedHandler
  :: Int
  -> Int
  -> TargetAgentIdentity
  -> TargetEpochExecutionInterpreter IO
  -> RequestSigningCapability IO
  -> IO (Either Text AuthorityTime)
  -> VerifiedControlPlaneRequest
  -> IO (Maybe (ReplyStatus, ByteString))
targetEpochDeadlineBoundedHandler maximumRequest maximumResponse localAgent interpreter signer readTime verified
  | not
      ( isSignedTargetEpochObservationForRole
          maximumRequest
          TargetSecretAgentRuntime
          (verifiedRequestRoute verified)
          (verifiedRequestBody verified)
      ) =
      targetEpochVerifiedHandler maximumRequest localAgent interpreter verified
  | otherwise = do
      opening <- readTime
      case opening of
        Left _ -> pure refusal
        Right now
          | now >= deadline -> pure refusal
          | otherwise -> do
              let remaining = min (authorityTimeMicros deadline - authorityTimeMicros now) (fromIntegral (maxBound :: Int))
              result <- timeout (fromIntegral remaining) $ do
                response <-
                  targetEpochNegotiatedHandler maximumRequest maximumResponse localAgent interpreter signer verified
                closing <- readTime
                pure $ case closing of
                  Right finished | finished < deadline -> response
                  _ -> refusal
              pure (maybe refusal id result)
 where
  deadline = verifiedRequestDeadline verified
  refusal = Just (ReplyServiceUnavailable, "signed-observation-refused")

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
      Right (TargetEpochObserveSigned _) -> True
      Right (TargetEpochMutate _) -> False
      Left _ -> False

isSignedTargetEpochObservationForRole
  :: Int -> RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isSignedTargetEpochObservationForRole maximumBytes role route body =
  role == TargetSecretAgentRuntime
    && route == TargetSecretTrustInstall
    && case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
      Right (TargetAuthorityTrustRequest inner) -> case decodeTargetEpochRequest inner of
        Right (TargetEpochObserveSigned _) -> True
        _ -> False
      _ -> False
