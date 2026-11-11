{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Signed Authority reads coupled to an independently supplied snapshot.
-- The caller owns repository authentication, original deadline, admission and
-- any final CAS; a matching closing revision alone does not fence later work.
module Prodbox.ControlPlane.AuthoritySnapshotObservation
  ( AuthoritySnapshotObservation
  , AuthoritySnapshotObservationError (..)
  , observeAuthorityPeerFromSnapshot
  , observeAuthorityPromotionFromSnapshot
  , authoritySnapshotObservationValue
  , authoritySnapshotObservationSnapshot
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientTransport)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionSnapshot)
import Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClientError
  , observeEpochPromotionWithVerifiedResponse
  )
import Prodbox.ControlPlane.AuthorityPeerContext (AuthorityPeerContext)
import Prodbox.ControlPlane.AuthorityPeerContextClient
  ( AuthorityPeerContextClientError
  , requestAuthorityPeerContextWithVerifiedResponse
  )
import Prodbox.ControlPlane.AuthorityResponseTrust
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication (TrustedRequestKey)
import Prodbox.ControlPlane.RpcKeyRegistry (RpcKeyOrigin)
import Prodbox.Lifecycle.Authority.EpochPromotionObservation (EpochPromotionObservation)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthoritySnapshotObservation revision value
  = AuthoritySnapshotObservation !(AuthorityResponseTrust revision) !value

data AuthoritySnapshotObservationError
  = AuthoritySnapshotTrustRefused !AuthorityResponseTrustError
  | AuthoritySnapshotPeerRefused !AuthorityPeerContextClientError
  | AuthoritySnapshotPromotionRefused !AuthorityControlClientError
  | AuthoritySnapshotClosingUnavailable
  deriving stock (Eq, Show)

observeAuthorityPeerFromSnapshot
  :: (Eq revision)
  => AuthorityScope
  -> RpcKeyOrigin
  -> AuthorityAdmissionSnapshot revision
  -> IO (Either Text (AuthorityAdmissionSnapshot revision))
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO
       ( Either
           AuthoritySnapshotObservationError
           (AuthoritySnapshotObservation revision AuthorityPeerContext)
       )
observeAuthorityPeerFromSnapshot scope origin snapshot readClosing transport =
  observeFromSnapshot scope origin snapshot readClosing $ \key ->
    first AuthoritySnapshotPeerRefused
      <$> requestAuthorityPeerContextWithVerifiedResponse scope key transport

observeAuthorityPromotionFromSnapshot
  :: (Eq revision)
  => AuthorityScope
  -> RpcKeyOrigin
  -> AuthorityAdmissionSnapshot revision
  -> IO (Either Text (AuthorityAdmissionSnapshot revision))
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO
       ( Either
           AuthoritySnapshotObservationError
           (AuthoritySnapshotObservation revision EpochPromotionObservation)
       )
observeAuthorityPromotionFromSnapshot scope origin snapshot readClosing transport =
  observeFromSnapshot scope origin snapshot readClosing $ \key ->
    first AuthoritySnapshotPromotionRefused <$> observeEpochPromotionWithVerifiedResponse transport key

observeFromSnapshot
  :: (Eq revision)
  => AuthorityScope
  -> RpcKeyOrigin
  -> AuthorityAdmissionSnapshot revision
  -> IO (Either Text (AuthorityAdmissionSnapshot revision))
  -> (TrustedRequestKey -> IO (Either AuthoritySnapshotObservationError value))
  -> IO (Either AuthoritySnapshotObservationError (AuthoritySnapshotObservation revision value))
observeFromSnapshot scope origin snapshot readClosing observe =
  case first AuthoritySnapshotTrustRefused (selectAuthorityResponseTrust scope origin snapshot) of
    Left failure -> pure (Left failure)
    Right trust -> do
      result <- observe (authorityResponseTrustKey trust)
      case result of
        Left failure -> pure (Left failure)
        Right value -> do
          closing <- readClosing
          pure $ do
            lastSnapshot <- first (const AuthoritySnapshotClosingUnavailable) closing
            first AuthoritySnapshotTrustRefused (checkAuthorityResponseTrust trust lastSnapshot)
            pure (AuthoritySnapshotObservation trust value)

authoritySnapshotObservationValue :: AuthoritySnapshotObservation revision value -> value
authoritySnapshotObservationValue (AuthoritySnapshotObservation _ value) = value

authoritySnapshotObservationSnapshot
  :: AuthoritySnapshotObservation revision value -> AuthorityAdmissionSnapshot revision
authoritySnapshotObservationSnapshot (AuthoritySnapshotObservation trust _) = authorityResponseTrustSnapshot trust
