{-# LANGUAGE OverloadedStrings #-}

-- | Opt-in signed Authority observation composition. Runtime dispatch, key
-- provenance, replay, deadlines and response capacity are caller-owned.
module Prodbox.ControlPlane.AuthoritySignedObservationEndpoint
  ( authoritySignedObservationHandler
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository
  , authorityTransitionHttpStatus
  , authorityTransitionResponseBody
  , serveAuthorityControlRequest
  )
import Prodbox.ControlPlane.AuthorityAuthenticatedResponse
import Prodbox.ControlPlane.AuthorityControlProtocol (isEpochPromotionObservationForRole)
import Prodbox.ControlPlane.AuthorityPeerContext (AuthorityPeerContextInterpreter)
import Prodbox.ControlPlane.AuthorityPeerContextEndpoint
  ( authorityPeerContextVerifiedHandler
  , isAuthorityPeerContextObservationForRole
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

authoritySignedObservationHandler
  :: (Monad m)
  => Int
  -> Int
  -> AuthorityScope
  -> AuthorityPeerContextInterpreter m
  -> AuthorityAdmissionRepository m revision
  -> RequestSigningCapability m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (Either AuthorityAuthenticatedResponseError ByteString))
authoritySignedObservationHandler maximumRequest maximumResponse scope peer repository signer verified
  | not (isAuthoritySignedObservation verified && ownsRoute) = pure Nothing
  | verifiedRequestAuthorityScope verified /= scope =
      pure (Just (Left AuthorityResponseRequestRefused))
  | otherwise = do
      observed <- authorityPeerContextVerifiedHandler scope peer verified
      case observed of
        Just (status, body) -> signed (fromIntegral (replyStatusCode status)) body
        Nothing
          | isEpochPromotionObservationForRole
              LifecycleAuthorityRuntime
              (verifiedRequestRoute verified)
              (verifiedRequestBody verified) -> do
              result <-
                serveAuthorityControlRequest
                  maximumRequest
                  repository
                  (LazyByteString.fromStrict (verifiedRequestBody verified))
              signed
                (fromIntegral (replyStatusCode (authorityTransitionHttpStatus result)))
                (LazyByteString.toStrict (authorityTransitionResponseBody result))
          | otherwise -> pure (Just (Left AuthorityResponseRequestRefused))
 where
  ownsRoute =
    isAuthorityPeerContextObservationForRole
      LifecycleAuthorityRuntime
      (verifiedRequestRoute verified)
      (verifiedRequestBody verified)
      || isEpochPromotionObservationForRole
        LifecycleAuthorityRuntime
        (verifiedRequestRoute verified)
        (verifiedRequestBody verified)
  signed status body = Just <$> signAuthorityAuthenticatedResponse maximumResponse signer verified status body
