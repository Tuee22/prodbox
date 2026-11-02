{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Prodbox.ControlPlane.AuthorityPeerContextEndpoint
  ( authorityPeerContextVerifiedHandler
  , isAuthorityPeerContextObservationForRole
  , vaultAuthorityPeerContextInterpreter
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Prodbox.ControlPlane.AuthorityPeerContext
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedControlPlaneRequest
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleAuthorityPeerObserve))
import Prodbox.ControlPlane.TargetAuthorityEpochExecution
  ( TargetEpochExecutionError (..)
  , TargetEpochExecutionInterpreter (..)
  , TargetEpochExecutionProgram (..)
  , vaultTargetEpochExecutionInterpreter
  )
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (ReplyBadRequest, ReplyConflict, ReplyOk, ReplyServiceUnavailable)
  )
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Vault.Session (VaultSession)

authorityPeerContextVerifiedHandler
  :: (Monad m)
  => Coordinate.AuthorityScope
  -> AuthorityPeerContextInterpreter m
  -> VerifiedControlPlaneRequest
  -> m (Maybe (ReplyStatus, ByteString))
authorityPeerContextVerifiedHandler scope interpreter verified
  | verifiedRequestRoute verified /= LifecycleAuthorityPeerObserve = pure Nothing
  | otherwise = do
      result <- observeAuthorityPeerContext scope interpreter verified
      pure (Just (status result, encodeAuthorityPeerContextResponse result))
 where
  status result = case result of
    Right _ -> ReplyOk
    Left PeerContextRequestInvalid -> ReplyBadRequest
    Left PeerContextBindingInvalid -> ReplyConflict
    Left PeerContextDeadlineReached -> ReplyConflict
    Left PeerContextFactsChanged -> ReplyConflict
    Left PeerContextRequestEpochAhead -> ReplyConflict
    Left PeerContextClockUnavailable -> ReplyServiceUnavailable
    Left PeerContextEpochUnavailable -> ReplyServiceUnavailable
    Left PeerContextIssuerUnavailable -> ReplyServiceUnavailable
    Left PeerContextEffectTimedOut -> ReplyServiceUnavailable
    Left PeerContextResponseInvalid -> ReplyServiceUnavailable

isAuthorityPeerContextObservationForRole :: RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isAuthorityPeerContextObservationForRole role route body =
  role == LifecycleAuthorityRuntime
    && route == LifecycleAuthorityPeerObserve
    && isAuthorityPeerContextRequest body

-- This adapter exposes only the three read effects of the existing bounded
-- Vault interpreter. Its row-CAS capability cannot enter the peer program.
vaultAuthorityPeerContextInterpreter
  :: VaultSession -> IO (Either Text AuthorityTime) -> AuthorityPeerContextInterpreter IO
vaultAuthorityPeerContextInterpreter session readTime = AuthorityPeerContextInterpreter interpret
 where
  target = vaultTargetEpochExecutionInterpreter session readTime
  interpret :: AuthorityPeerContextProgram result -> IO (Either AuthorityPeerContextError result)
  interpret program = case program of
    ReadPeerContextTime ->
      first (const PeerContextClockUnavailable)
        <$> runTargetEpochExecutionProgram target ReadTargetEpochTime
    ReadPeerContextEpoch deadline -> do
      result <- runTargetEpochExecutionProgram target (ReadPublishedTargetEpoch deadline)
      pure $ do
        Coordinate.AuthorityEpoch value <- first (projectFailure PeerContextEpochUnavailable) result
        maybe (Left PeerContextEpochUnavailable) Right (Genesis.authorityEpochFromValue value)
    ReadPeerContextIssuer deadline ->
      first (projectFailure PeerContextIssuerUnavailable)
        <$> runTargetEpochExecutionProgram target (ReadTargetEpochIssuer deadline)
  projectFailure fallback failure = case failure of
    TargetEpochClockUnavailable -> PeerContextClockUnavailable
    TargetEpochExecutionDeadlineReached -> PeerContextDeadlineReached
    TargetEpochEffectTimedOut -> PeerContextEffectTimedOut
    TargetEpochRequestBindingInvalid -> fallback
    TargetEpochLocalAgentMismatch -> fallback
    TargetEpochPublishedEpochUnavailable -> fallback
    TargetEpochIssuerUnavailable -> fallback
    TargetEpochIssuerMismatch -> fallback
    TargetEpochRequestEpochChanged -> fallback
    TargetEpochStoreFailed _ -> fallback
    TargetEpochRecordCodecFailed _ -> fallback
    TargetEpochTransitionRefused _ -> fallback
    TargetEpochReadBackChanged -> fallback
