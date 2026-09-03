{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Monotonic, target-local installation of the public Authority record used
-- by one-shot Target workers.  The Agent owns the exact KV coordinate; the
-- Authority can submit only the closed public record over its authenticated
-- route.  Every write is CAS-bound and confirmed by a fresh read-back.
module Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustObservation (..)
  , TargetAuthorityTrustObservationCause (..)
  , allTargetAuthorityTrustObservationCauses
  , renderTargetAuthorityTrustObservationCause
  , parseTargetAuthorityTrustObservationCause
  , classifyTargetAuthorityTrustRecord
  , targetAuthorityTrustDesiredMatchesLocal
  , TargetAuthorityTrustRepository (..)
  , TargetAuthorityTrustInstallResult (..)
  , TargetAuthorityTrustInstallError (..)
  , TargetAuthorityTrustBoundaryCause (..)
  , allTargetAuthorityTrustBoundaryCauses
  , renderTargetAuthorityTrustBoundaryCause
  , parseTargetAuthorityTrustBoundaryCause
  , installTargetAuthorityTrust
  )
where

import Data.List (find)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClientCause
  , allTargetMaterialClientCauses
  , renderTargetMaterialClientCause
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentIdentity
  , acceptedTargetAgentIdentity
  , acceptedTargetAuthorityEpoch
  , acceptedTargetFenceFloor
  , acceptedTargetId
  , acceptedTargetIssuerGeneration
  , acceptedTargetIssuerIdentity
  , acceptedTargetIssuerPublicKey
  , targetAgentClusterIdentity
  , targetIssuerKeyGenerationValue
  )
import Prodbox.Lifecycle.Lease (fencingTokenValue)

data TargetAuthorityTrustObservation
  = TargetAuthorityTrustMissing
  | TargetAuthorityTrustObserved !Natural !AcceptedTargetAuthority
  | TargetAuthorityTrustUnobservable !TargetAuthorityTrustObservationCause
  deriving stock (Eq, Show)

-- | Value-free provenance for the Target Agent's exact trust-record read.
-- Session and request failures stay distinct, while stored record bytes and
-- identities never cross the repository boundary.
data TargetAuthorityTrustObservationCause
  = TargetAuthorityTrustObservationSessionAcquisitionSealed
  | TargetAuthorityTrustObservationSessionAcquisitionForbidden
  | TargetAuthorityTrustObservationSessionAcquisitionUnavailable
  | TargetAuthorityTrustObservationSessionReloginSealed
  | TargetAuthorityTrustObservationSessionReloginForbidden
  | TargetAuthorityTrustObservationSessionReloginUnavailable
  | TargetAuthorityTrustObservationRequestUnauthorized
  | TargetAuthorityTrustObservationRequestForbidden
  | TargetAuthorityTrustObservationRequestClientFailure
  | TargetAuthorityTrustObservationRequestServerFailure
  | TargetAuthorityTrustObservationRequestUnexpectedStatus
  | TargetAuthorityTrustObservationRequestConnectionFailure
  | TargetAuthorityTrustObservationRequestTimeout
  | TargetAuthorityTrustObservationRequestDecodeFailure
  | TargetAuthorityTrustObservationFieldAbsent
  | TargetAuthorityTrustObservationFieldBase64Invalid
  | TargetAuthorityTrustObservationRecordInvalid
  | TargetAuthorityTrustObservationTargetMismatch
  | TargetAuthorityTrustObservationAgentIdentityMismatch
  | TargetAuthorityTrustObservationOther
  deriving stock (Bounded, Enum, Eq, Show)

allTargetAuthorityTrustObservationCauses :: [TargetAuthorityTrustObservationCause]
allTargetAuthorityTrustObservationCauses = [minBound .. maxBound]

renderTargetAuthorityTrustObservationCause :: TargetAuthorityTrustObservationCause -> Text
renderTargetAuthorityTrustObservationCause cause = case cause of
  TargetAuthorityTrustObservationSessionAcquisitionSealed -> "session-acquisition/sealed"
  TargetAuthorityTrustObservationSessionAcquisitionForbidden -> "session-acquisition/forbidden"
  TargetAuthorityTrustObservationSessionAcquisitionUnavailable -> "session-acquisition/unavailable"
  TargetAuthorityTrustObservationSessionReloginSealed -> "session-relogin/sealed"
  TargetAuthorityTrustObservationSessionReloginForbidden -> "session-relogin/forbidden"
  TargetAuthorityTrustObservationSessionReloginUnavailable -> "session-relogin/unavailable"
  TargetAuthorityTrustObservationRequestUnauthorized -> "request/unauthorized"
  TargetAuthorityTrustObservationRequestForbidden -> "request/forbidden"
  TargetAuthorityTrustObservationRequestClientFailure -> "request/client-failure"
  TargetAuthorityTrustObservationRequestServerFailure -> "request/server-failure"
  TargetAuthorityTrustObservationRequestUnexpectedStatus -> "request/unexpected-status"
  TargetAuthorityTrustObservationRequestConnectionFailure -> "request/connection-failure"
  TargetAuthorityTrustObservationRequestTimeout -> "request/timeout"
  TargetAuthorityTrustObservationRequestDecodeFailure -> "request/decode-failure"
  TargetAuthorityTrustObservationFieldAbsent -> "record/field-absent"
  TargetAuthorityTrustObservationFieldBase64Invalid -> "record/field-base64-invalid"
  TargetAuthorityTrustObservationRecordInvalid -> "record/invalid"
  TargetAuthorityTrustObservationTargetMismatch -> "record/target-mismatch"
  TargetAuthorityTrustObservationAgentIdentityMismatch -> "record/agent-identity-mismatch"
  TargetAuthorityTrustObservationOther -> "other"

parseTargetAuthorityTrustObservationCause
  :: Text -> Maybe TargetAuthorityTrustObservationCause
parseTargetAuthorityTrustObservationCause token =
  find
    ((== token) . renderTargetAuthorityTrustObservationCause)
    allTargetAuthorityTrustObservationCauses

-- | Interpret a decoded stored record against the endpoint's selected target
-- and current Agent. A same-cluster prior rollout is observable so the
-- monotonic installer can CAS-adopt the current exact rollout; a foreign
-- cluster remains unobservable and cannot supply write authority.
classifyTargetAuthorityTrustRecord
  :: TargetAgentIdentity
  -> TargetSecretId
  -> Natural
  -> AcceptedTargetAuthority
  -> TargetAuthorityTrustObservation
classifyTargetAuthorityTrustRecord localAgentIdentity target version accepted
  | acceptedTargetId accepted /= target =
      TargetAuthorityTrustUnobservable
        TargetAuthorityTrustObservationTargetMismatch
  | targetAgentClusterIdentity (acceptedTargetAgentIdentity accepted)
      /= targetAgentClusterIdentity localAgentIdentity =
      TargetAuthorityTrustUnobservable
        TargetAuthorityTrustObservationAgentIdentityMismatch
  | otherwise = TargetAuthorityTrustObserved version accepted

-- | CAS input must always name the endpoint's exact current rollout. Stored
-- same-cluster history is deliberately broader only on the observation side.
targetAuthorityTrustDesiredMatchesLocal
  :: TargetAgentIdentity -> TargetSecretId -> AcceptedTargetAuthority -> Bool
targetAuthorityTrustDesiredMatchesLocal localAgentIdentity target accepted =
  acceptedTargetId accepted == target
    && acceptedTargetAgentIdentity accepted == localAgentIdentity

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
  = TargetAuthorityTrustObservationUnavailable !TargetAuthorityTrustObservationCause
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

-- | Payload-free cause carried across the Authority -> Target Agent trust
-- installation wire. The generic authenticated client portion reuses the
-- closed Target-material client vocabulary; semantic refusal/unavailability
-- remains specific to the trust endpoint.
data TargetAuthorityTrustBoundaryCause
  = TargetAuthorityTrustBoundaryClient !TargetMaterialClientCause
  | TargetAuthorityTrustBoundaryRefusedRequestCodec
  | TargetAuthorityTrustBoundaryRefusedAcceptedAuthority
  | TargetAuthorityTrustBoundaryRefusedTargetMismatch
  | TargetAuthorityTrustBoundaryRefusedAgentIdentityChanged
  | TargetAuthorityTrustBoundaryRefusedIssuerIdentityChanged
  | TargetAuthorityTrustBoundaryRefusedIssuerGenerationRegressed
  | TargetAuthorityTrustBoundaryRefusedIssuerKeyConflict
  | TargetAuthorityTrustBoundaryRefusedEpochRegressed
  | TargetAuthorityTrustBoundaryRefusedFenceRegressed
  | TargetAuthorityTrustBoundaryRefusedReadBackMismatch
  | TargetAuthorityTrustBoundaryRefusedOther
  | TargetAuthorityTrustBoundaryUnavailableObservation !TargetAuthorityTrustObservationCause
  | TargetAuthorityTrustBoundaryUnavailableCas
  | TargetAuthorityTrustBoundaryUnavailableOther
  | TargetAuthorityTrustBoundaryReadBackInvalid
  | TargetAuthorityTrustBoundaryReadBackMismatch
  | TargetAuthorityTrustBoundaryOther
  deriving stock (Eq, Show)

allTargetAuthorityTrustBoundaryCauses :: [TargetAuthorityTrustBoundaryCause]
allTargetAuthorityTrustBoundaryCauses =
  fmap TargetAuthorityTrustBoundaryClient allTargetMaterialClientCauses
    <> [ TargetAuthorityTrustBoundaryRefusedRequestCodec
       , TargetAuthorityTrustBoundaryRefusedAcceptedAuthority
       , TargetAuthorityTrustBoundaryRefusedTargetMismatch
       , TargetAuthorityTrustBoundaryRefusedAgentIdentityChanged
       , TargetAuthorityTrustBoundaryRefusedIssuerIdentityChanged
       , TargetAuthorityTrustBoundaryRefusedIssuerGenerationRegressed
       , TargetAuthorityTrustBoundaryRefusedIssuerKeyConflict
       , TargetAuthorityTrustBoundaryRefusedEpochRegressed
       , TargetAuthorityTrustBoundaryRefusedFenceRegressed
       , TargetAuthorityTrustBoundaryRefusedReadBackMismatch
       , TargetAuthorityTrustBoundaryRefusedOther
       ]
    <> fmap
      TargetAuthorityTrustBoundaryUnavailableObservation
      allTargetAuthorityTrustObservationCauses
    <> [ TargetAuthorityTrustBoundaryUnavailableCas
       , TargetAuthorityTrustBoundaryUnavailableOther
       , TargetAuthorityTrustBoundaryReadBackInvalid
       , TargetAuthorityTrustBoundaryReadBackMismatch
       , TargetAuthorityTrustBoundaryOther
       ]

renderTargetAuthorityTrustBoundaryCause :: TargetAuthorityTrustBoundaryCause -> Text
renderTargetAuthorityTrustBoundaryCause cause = case cause of
  TargetAuthorityTrustBoundaryClient client ->
    "client/" <> renderTargetMaterialClientCause client
  TargetAuthorityTrustBoundaryRefusedRequestCodec -> "refused/request-codec"
  TargetAuthorityTrustBoundaryRefusedAcceptedAuthority -> "refused/accepted-authority"
  TargetAuthorityTrustBoundaryRefusedTargetMismatch -> "refused/target-mismatch"
  TargetAuthorityTrustBoundaryRefusedAgentIdentityChanged ->
    "refused/agent-identity-changed"
  TargetAuthorityTrustBoundaryRefusedIssuerIdentityChanged ->
    "refused/issuer-identity-changed"
  TargetAuthorityTrustBoundaryRefusedIssuerGenerationRegressed ->
    "refused/issuer-generation-regressed"
  TargetAuthorityTrustBoundaryRefusedIssuerKeyConflict -> "refused/issuer-key-conflict"
  TargetAuthorityTrustBoundaryRefusedEpochRegressed -> "refused/epoch-regressed"
  TargetAuthorityTrustBoundaryRefusedFenceRegressed -> "refused/fence-regressed"
  TargetAuthorityTrustBoundaryRefusedReadBackMismatch -> "refused/read-back-mismatch"
  TargetAuthorityTrustBoundaryRefusedOther -> "refused/other"
  TargetAuthorityTrustBoundaryUnavailableObservation observation ->
    "unavailable/observation/" <> renderTargetAuthorityTrustObservationCause observation
  TargetAuthorityTrustBoundaryUnavailableCas -> "unavailable/cas"
  TargetAuthorityTrustBoundaryUnavailableOther -> "unavailable/other"
  TargetAuthorityTrustBoundaryReadBackInvalid -> "read-back/invalid"
  TargetAuthorityTrustBoundaryReadBackMismatch -> "read-back/mismatch"
  TargetAuthorityTrustBoundaryOther -> "other"

parseTargetAuthorityTrustBoundaryCause :: Text -> Maybe TargetAuthorityTrustBoundaryCause
parseTargetAuthorityTrustBoundaryCause token =
  find
    ((== token) . renderTargetAuthorityTrustBoundaryCause)
    allTargetAuthorityTrustBoundaryCauses

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
  | targetAgentClusterIdentity (acceptedTargetAgentIdentity current)
      /= targetAgentClusterIdentity (acceptedTargetAgentIdentity desired) =
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
