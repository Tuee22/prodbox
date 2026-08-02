{-# LANGUAGE DerivingStrategies #-}

-- | Monotonic, target-local installation of the public Authority record used
-- by one-shot Target workers.  The Agent owns the exact KV coordinate; the
-- Authority can submit only the closed public record over its authenticated
-- route.  Every write is CAS-bound and confirmed by a fresh read-back.
module Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustObservation (..)
  , TargetAuthorityTrustRepository (..)
  , TargetAuthorityTrustInstallResult (..)
  , TargetAuthorityTrustInstallError (..)
  , installTargetAuthorityTrust
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , acceptedTargetAgentIdentity
  , acceptedTargetAuthorityEpoch
  , acceptedTargetFenceFloor
  , acceptedTargetId
  , acceptedTargetIssuerGeneration
  , acceptedTargetIssuerIdentity
  , acceptedTargetIssuerPublicKey
  , targetIssuerKeyGenerationValue
  )
import Prodbox.Lifecycle.Lease (fencingTokenValue)

data TargetAuthorityTrustObservation
  = TargetAuthorityTrustMissing
  | TargetAuthorityTrustObserved !Natural !AcceptedTargetAuthority
  | TargetAuthorityTrustUnobservable !Text

data TargetAuthorityTrustRepository m = TargetAuthorityTrustRepository
  { observeTargetAuthorityTrust
      :: TargetSecretId
      -> m TargetAuthorityTrustObservation
  , compareAndSwapTargetAuthorityTrust
      :: TargetSecretId
      -> Natural
      -> AcceptedTargetAuthority
      -> m (Either Text ())
  }

data TargetAuthorityTrustInstallResult
  = TargetAuthorityTrustInstalled !AcceptedTargetAuthority
  | TargetAuthorityTrustAlreadyInstalled !AcceptedTargetAuthority
  | TargetAuthorityTrustRecovered !AcceptedTargetAuthority
  deriving stock (Eq, Show)

data TargetAuthorityTrustInstallError
  = TargetAuthorityTrustObservationUnavailable !Text
  | TargetAuthorityTrustTargetMismatch
  | TargetAuthorityTrustAgentIdentityChanged
  | TargetAuthorityTrustIssuerIdentityChanged
  | TargetAuthorityTrustIssuerGenerationRegressed
  | TargetAuthorityTrustIssuerKeyConflict
  | TargetAuthorityTrustEpochRegressed
  | TargetAuthorityTrustFenceRegressed
  | TargetAuthorityTrustCasFailed !Text
  | TargetAuthorityTrustReadBackMismatch
  deriving stock (Eq, Show)

installTargetAuthorityTrust
  :: (Monad m)
  => TargetAuthorityTrustRepository m
  -> AcceptedTargetAuthority
  -> m
       ( Either
           TargetAuthorityTrustInstallError
           TargetAuthorityTrustInstallResult
       )
installTargetAuthorityTrust repository desired = do
  observed <- observeTargetAuthorityTrust repository target
  case observed of
    TargetAuthorityTrustUnobservable detail ->
      pure (Left (TargetAuthorityTrustObservationUnavailable detail))
    TargetAuthorityTrustMissing -> applyCas 0 TargetAuthorityTrustInstalled
    TargetAuthorityTrustObserved version current
      | acceptedTargetId current /= target ->
          pure (Left TargetAuthorityTrustTargetMismatch)
      | current == desired ->
          pure (Right (TargetAuthorityTrustAlreadyInstalled current))
      | otherwise -> case validateAdvance current desired of
          Left err -> pure (Left err)
          Right () -> applyCas version TargetAuthorityTrustInstalled
 where
  target = acceptedTargetId desired

  applyCas expected constructor = do
    attempted <-
      compareAndSwapTargetAuthorityTrust repository target expected desired
    readBack <- observeTargetAuthorityTrust repository target
    pure $ case readBack of
      TargetAuthorityTrustObserved _ actual
        | actual == desired ->
            Right
              ( case attempted of
                  Right () -> constructor desired
                  Left _ -> TargetAuthorityTrustRecovered desired
              )
      TargetAuthorityTrustUnobservable detail ->
        Left
          ( case attempted of
              Left failure -> TargetAuthorityTrustCasFailed failure
              Right () -> TargetAuthorityTrustObservationUnavailable detail
          )
      _ -> case attempted of
        Left detail -> Left (TargetAuthorityTrustCasFailed detail)
        Right () -> Left TargetAuthorityTrustReadBackMismatch

validateAdvance
  :: AcceptedTargetAuthority
  -> AcceptedTargetAuthority
  -> Either TargetAuthorityTrustInstallError ()
validateAdvance current desired
  | acceptedTargetId current /= acceptedTargetId desired =
      Left TargetAuthorityTrustTargetMismatch
  | acceptedTargetAgentIdentity current /= acceptedTargetAgentIdentity desired =
      Left TargetAuthorityTrustAgentIdentityChanged
  | acceptedTargetIssuerIdentity current /= acceptedTargetIssuerIdentity desired =
      Left TargetAuthorityTrustIssuerIdentityChanged
  | desiredGeneration < currentGeneration =
      Left TargetAuthorityTrustIssuerGenerationRegressed
  | desiredGeneration == currentGeneration
      && acceptedTargetIssuerPublicKey current
        /= acceptedTargetIssuerPublicKey desired =
      Left TargetAuthorityTrustIssuerKeyConflict
  | desiredEpoch < currentEpoch =
      Left TargetAuthorityTrustEpochRegressed
  | desiredEpoch == currentEpoch && desiredFence < currentFence =
      Left TargetAuthorityTrustFenceRegressed
  | otherwise = Right ()
 where
  desiredGeneration =
    targetIssuerKeyGenerationValue (acceptedTargetIssuerGeneration desired)
  currentGeneration =
    targetIssuerKeyGenerationValue (acceptedTargetIssuerGeneration current)
  desiredEpoch = epochValue (acceptedTargetAuthorityEpoch desired)
  currentEpoch = epochValue (acceptedTargetAuthorityEpoch current)
  desiredFence = fencingTokenValue (acceptedTargetFenceFloor desired)
  currentFence = fencingTokenValue (acceptedTargetFenceFloor current)
  epochValue (AuthorityEpoch value) = value
