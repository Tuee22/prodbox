{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

module Prodbox.ControlPlane.AuthorityPeerContextClient
  ( AuthorityPeerContextClientError (..)
  , requestAuthorityPeerContext
  , requestAuthorityPeerContextWithin
  , requestAuthorityPeerContextWithVerifiedResponse
  , decodeAuthorityPeerContextClientResponse
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedPeerObservation
  , callAuthenticatedPeerObservationWithSignedRequest
  , resolveAuthenticatedClientTransportDeadline
  )
import Prodbox.ControlPlane.AuthorityAuthenticatedResponse
  ( AuthorityAuthenticatedResponseError
  , verifyAuthorityAuthenticatedResponse
  )
import Prodbox.ControlPlane.AuthorityPeerContext
import Prodbox.ControlPlane.Client (ControlPlaneResponse (..))
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication (TrustedRequestKey)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import System.Timeout (timeout)

data AuthorityPeerContextClientError
  = PeerContextClientTransportFailed !AuthenticatedClientError
  | PeerContextClientResponseAuthenticationFailed !AuthorityAuthenticatedResponseError
  | PeerContextClientHttpStatus !Int
  | PeerContextClientRejected !AuthorityPeerContextError
  | PeerContextClientScopeMismatch
  | PeerContextClientClockUnavailable
  | PeerContextClientDeadlineReached
  | PeerContextClientTimedOut
  deriving stock (Eq, Show)

requestAuthorityPeerContext
  :: AuthorityScope
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either AuthorityPeerContextClientError AuthorityPeerContext)
requestAuthorityPeerContext scope transport = do
  result <- callAuthenticatedPeerObservation transport authorityPeerContextRequest
  pure $
    first PeerContextClientTransportFailed result
      >>= decodeAuthorityPeerContextClientResponse scope

-- | The caller selects the Authority key independently and owns a complete
-- original deadline and capacity envelope around signing and verification.
requestAuthorityPeerContextWithVerifiedResponse
  :: AuthorityScope
  -> TrustedRequestKey
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either AuthorityPeerContextClientError AuthorityPeerContext)
requestAuthorityPeerContextWithVerifiedResponse scope trusted transport = do
  attempted <-
    callAuthenticatedPeerObservationWithSignedRequest transport signedAuthorityPeerContextRequest
  pure $ do
    (request, ControlPlaneResponse outerStatus envelope) <-
      first PeerContextClientTransportFailed attempted
    if outerStatus == 200 then pure () else Left (PeerContextClientHttpStatus outerStatus)
    (status, body) <-
      first
        PeerContextClientResponseAuthenticationFailed
        (verifyAuthorityAuthenticatedResponse authorityPeerContextMaximumBytes trusted request envelope)
    decodeAuthorityPeerContextClientResponse scope (ControlPlaneResponse (fromIntegral status) body)

-- | A caller's original absolute deadline covers deadline-provider resolution,
-- signing, nonce generation, HTTP and response decoding. An earlier transport
-- deadline is sampled once and also bounds the complete inner operation.
requestAuthorityPeerContextWithin
  :: IO (Either Text AuthorityTime)
  -> AuthorityTime
  -> AuthorityScope
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either AuthorityPeerContextClientError AuthorityPeerContext)
requestAuthorityPeerContextWithin readTime parent scope transport = before parent $ do
  resolved <- resolveAuthenticatedClientTransportDeadline parent transport
  case resolved of
    Left err -> pure (Left (PeerContextClientTransportFailed err))
    Right (deadline, boundedTransport) -> before deadline (requestAuthorityPeerContext scope boundedTransport)
 where
  before
    :: AuthorityTime
    -> IO (Either AuthorityPeerContextClientError result)
    -> IO (Either AuthorityPeerContextClientError result)
  before deadline effect = do
    observed <- readTime
    case observed of
      Left _ -> pure (Left PeerContextClientClockUnavailable)
      Right now
        | now >= deadline -> pure (Left PeerContextClientDeadlineReached)
        | otherwise -> do
            let remaining = authorityTimeMicros deadline - authorityTimeMicros now
                micros = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
            attempted <- timeout micros $ do
              result <- effect
              case result of
                Left err -> err `seq` pure (Left err)
                Right value -> value `seq` pure (Right value)
            case attempted of
              Nothing -> pure (Left PeerContextClientTimedOut)
              Just result -> do
                closing <- readTime
                pure $ case closing of
                  Left _ -> Left PeerContextClientClockUnavailable
                  Right after
                    | after >= deadline -> Left PeerContextClientDeadlineReached
                    | otherwise -> result

decodeAuthorityPeerContextClientResponse
  :: AuthorityScope
  -> ControlPlaneResponse
  -> Either AuthorityPeerContextClientError AuthorityPeerContext
decodeAuthorityPeerContextClientResponse scope (ControlPlaneResponse status body) = do
  context <- first PeerContextClientRejected (decodeAuthorityPeerContextResponse body)
  if status == 200 then pure () else Left (PeerContextClientHttpStatus status)
  if peerContextScope context == scope then Right context else Left PeerContextClientScopeMismatch
