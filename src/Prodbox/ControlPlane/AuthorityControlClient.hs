{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client for the Lifecycle Authority's closed control fold.
-- The request is a typed genesis/repair/migration command; callers must
-- re-observe the retained admission projection after success or response loss.
module Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClient (..)
  , AuthorityControlClientError (..)
  , authorityControlClientWithTransport
  , observeProviderAdmissionRecoveryWithTransport
  , decodeProviderAdmissionRecoveryResponse
  , observeProviderBootstrapPredecessorWithTransport
  , decodeProviderBootstrapPredecessorResponse
  , decodeAuthorityControlTextResponse
  , observeEpochPromotionWithTransport
  , observeEpochPromotionWithVerifiedResponse
  , decodeEpochPromotionObservationResponse
  , EpochPromotionSubmission (..)
  , prepareEpochPromotionWithTransport
  , submitEpochPromotionWithTransport
  , decodeEpochPromotionSubmissionResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Capacity.ControlPlaneReplayBudget qualified as ReplayBudget
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedAuthorityObservationWithSignedRequest
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload
      ( AuthorityControlObserveEpochPromotion
      , AuthorityControlObserveProviderAdmissionRecovery
      , AuthorityControlObserveProviderBootstrapPredecessor
      , AuthorityControlObserveSignedEpochPromotion
      )
  )
import Prodbox.ControlPlane.AuthorityAuthenticatedResponse
  ( AuthorityAuthenticatedResponseError
  , verifyAuthorityAuthenticatedResponse
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAuthorityControlRoute, LifecycleMigrationApplyRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.RequestAuthentication (TrustedRequestKey)
import Prodbox.Lifecycle.Authority.EpochPromotion (EpochPromotionRequest)
import Prodbox.Lifecycle.Authority.EpochPromotionObservation
  ( EpochPromotionObservation
  , EpochPromotionObservationError
  , validateEpochPromotionObservation
  )
import Prodbox.Lifecycle.Authority.EpochTopology (EpochTopology)
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCommand (ApplyPreparedEpochPromotion, PrepareReplacementEpoch)
  , MigrationEpoch
  , encodeMigrationCommand
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , ProviderAdmissionEpochError
  , ProviderAdmissionRecoveryObservation
  , ProviderAdmissionRecoveryRefusal
  , ProviderBootstrapPredecessor
  , cascadeAuditRecoveryRequestDigest
  , providerAdmissionRecoveryRequestDigest
  , validateProviderAdmissionRecoveryObservation
  , validateProviderBootstrapPredecessor
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype AuthorityControlClient m = AuthorityControlClient
  { submitAuthorityControl
      :: AuthorityControlPayload
      -> m (Either AuthorityControlClientError Text)
  }

data AuthorityControlClientError
  = AuthorityControlTransportFailed !AuthenticatedClientError
  | AuthorityControlResponseAuthenticationFailed !AuthorityAuthenticatedResponseError
  | AuthorityControlRefused !Text
  | AuthorityControlHttpStatus !Int !Text
  | AuthorityControlResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityControlTextResponseTooLarge !Int !Int
  | AuthorityControlTextResponseInvalidUtf8
  | AuthorityControlRecoveryResponseMismatch
  | AuthorityControlRecoveryObservationInvalid !ProviderAdmissionRecoveryRefusal
  | AuthorityControlBootstrapPredecessorInvalid !ProviderAdmissionEpochError
  | AuthorityControlEpochObservationInvalid !EpochPromotionObservationError
  | AuthorityControlEpochObservationResponseMismatch
  | AuthorityControlEpochSubmissionResponseMismatch
  deriving stock (Eq, Show)

authorityControlClientWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityControlClient IO
authorityControlClientWithTransport transport =
  AuthorityControlClient
    { submitAuthorityControl = \payload -> do
        attempted <-
          callAuthenticatedClientTransport
            transport
            LifecycleAuthorityControlRoute
            (LazyByteString.toStrict (encodeControlPlaneRequest payload))
        pure (first AuthorityControlTransportFailed attempted >>= decodeAuthorityControlTextResponse)
    }

-- | Established control outcomes are bounded raw UTF-8, including failures
-- of the new metadata request. Only its successful DTO uses the CBOR codec.
decodeAuthorityControlTextResponse
  :: ControlPlaneResponse -> Either AuthorityControlClientError Text
decodeAuthorityControlTextResponse (ControlPlaneResponse status body) = do
  summary <- decodeAuthorityControlTextBody body
  case status of
    200 -> Right summary
    409 -> Left (AuthorityControlRefused summary)
    _ -> Left (AuthorityControlHttpStatus status summary)

decodeAuthorityControlTextBody :: ByteString.ByteString -> Either AuthorityControlClientError Text
decodeAuthorityControlTextBody body
  | ByteString.length body > authorityControlMaximumResponseBytes =
      Left
        (AuthorityControlTextResponseTooLarge (ByteString.length body) authorityControlMaximumResponseBytes)
  | otherwise = first (const AuthorityControlTextResponseInvalidUtf8) (TextEncoding.decodeUtf8' body)

authorityControlMaximumResponseBytes :: Int
authorityControlMaximumResponseBytes = 64 * 1024

observeEpochPromotionWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either AuthorityControlClientError EpochPromotionObservation)
observeEpochPromotionWithTransport transport = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityControlRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest AuthorityControlObserveEpochPromotion))
  pure (first AuthorityControlTransportFailed attempted >>= decodeEpochPromotionObservationResponse)

-- | The caller supplies an independently authenticated Authority key and
-- bounds the complete call, including key selection, by the original deadline.
observeEpochPromotionWithVerifiedResponse
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> TrustedRequestKey
  -> IO (Either AuthorityControlClientError EpochPromotionObservation)
observeEpochPromotionWithVerifiedResponse transport trusted = do
  attempted <-
    callAuthenticatedAuthorityObservationWithSignedRequest
      transport
      (LazyByteString.toStrict (encodeControlPlaneRequest AuthorityControlObserveSignedEpochPromotion))
  pure $ do
    (request, ControlPlaneResponse outerStatus envelope) <-
      first AuthorityControlTransportFailed attempted
    if outerStatus == 200
      then pure ()
      else Left (AuthorityControlHttpStatus outerStatus "signed-response-unavailable")
    (status, body) <-
      first
        AuthorityControlResponseAuthenticationFailed
        (verifyAuthorityAuthenticatedResponse authorityControlMaximumResponseBytes trusted request envelope)
    decodeEpochPromotionObservationResponse (ControlPlaneResponse (fromIntegral status) body)

-- | Acknowledgement of the endpoint's decision, not evidence that the
-- requested physical binding or the resulting admission state remains current.
data EpochPromotionSubmission
  = EpochPromotionSubmitted
  | EpochPromotionAlreadySubmitted
  deriving stock (Eq, Show)

-- | Prepare an exact topology under the existing frozen Authority. The
-- acknowledgement does not replace the subsequent retained observation.
prepareEpochPromotionWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> MigrationEpoch
  -> MigrationEpoch
  -> EpochTopology
  -> IO (Either AuthorityControlClientError EpochPromotionSubmission)
prepareEpochPromotionWithTransport transport predecessor target topology =
  submitEpochMigration transport (PrepareReplacementEpoch predecessor target topology)

submitEpochPromotionWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> EpochPromotionRequest
  -> IO (Either AuthorityControlClientError EpochPromotionSubmission)
submitEpochPromotionWithTransport transport request =
  submitEpochMigration transport (ApplyPreparedEpochPromotion request)

submitEpochMigration
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> MigrationCommand
  -> IO (Either AuthorityControlClientError EpochPromotionSubmission)
submitEpochMigration transport command = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleMigrationApplyRoute
      (LazyByteString.toStrict (encodeMigrationCommand command))
  pure (first AuthorityControlTransportFailed attempted >>= decodeEpochPromotionSubmissionResponse)

decodeEpochPromotionSubmissionResponse
  :: ControlPlaneResponse -> Either AuthorityControlClientError EpochPromotionSubmission
decodeEpochPromotionSubmissionResponse response = do
  summary <- decodeAuthorityControlTextResponse response
  case summary of
    "migration-accepted" -> Right EpochPromotionSubmitted
    "migration-already-applied" -> Right EpochPromotionAlreadySubmitted
    _ -> Left AuthorityControlEpochSubmissionResponseMismatch

decodeEpochPromotionObservationResponse
  :: ControlPlaneResponse -> Either AuthorityControlClientError EpochPromotionObservation
decodeEpochPromotionObservationResponse response@(ControlPlaneResponse status body)
  | status == 200 = do
      observation <-
        first
          AuthorityControlResponseInvalid
          ( decodeControlPlaneResponse
              ReplayBudget.authorityMetadataResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      _ <- first AuthorityControlEpochObservationInvalid (validateEpochPromotionObservation observation)
      pure observation
  | otherwise = do
      _ <- decodeAuthorityControlTextResponse response
      Left AuthorityControlEpochObservationResponseMismatch

-- | Discover the retained reservation after the host retired its active
-- intent. The authenticated reply is a locator, not a successor permit.
observeProviderBootstrapPredecessorWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either AuthorityControlClientError (Maybe ProviderBootstrapPredecessor))
observeProviderBootstrapPredecessorWithTransport transport = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityControlRoute
      ( LazyByteString.toStrict
          (encodeControlPlaneRequest AuthorityControlObserveProviderBootstrapPredecessor)
      )
  pure
    (first AuthorityControlTransportFailed attempted >>= decodeProviderBootstrapPredecessorResponse)

decodeProviderBootstrapPredecessorResponse
  :: ControlPlaneResponse
  -> Either AuthorityControlClientError (Maybe ProviderBootstrapPredecessor)
decodeProviderBootstrapPredecessorResponse response@(ControlPlaneResponse status body)
  | status == 200 = do
      predecessor <-
        first
          AuthorityControlResponseInvalid
          (decodeControlPlaneResponse authorityControlMaximumResponseBytes (LazyByteString.fromStrict body))
      mapM_
        (first AuthorityControlBootstrapPredecessorInvalid . validateProviderBootstrapPredecessor)
        predecessor
      Right predecessor
  | otherwise = do
      _ <- decodeAuthorityControlTextResponse response
      Left AuthorityControlRecoveryResponseMismatch

-- | Observe through the existing authenticated control route. The response
-- echoes the entire reservation identity except its replaceable lease attempt.
observeProviderAdmissionRecoveryWithTransport
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CascadeAuditFreezeBinding
  -> IO (Either AuthorityControlClientError ProviderAdmissionRecoveryObservation)
observeProviderAdmissionRecoveryWithTransport transport binding = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAuthorityControlRoute
      ( LazyByteString.toStrict
          (encodeControlPlaneRequest (AuthorityControlObserveProviderAdmissionRecovery binding))
      )
  pure $ do
    response <- first AuthorityControlTransportFailed attempted
    decodeProviderAdmissionRecoveryResponse binding response

decodeProviderAdmissionRecoveryResponse
  :: CascadeAuditFreezeBinding
  -> ControlPlaneResponse
  -> Either AuthorityControlClientError ProviderAdmissionRecoveryObservation
decodeProviderAdmissionRecoveryResponse binding (ControlPlaneResponse status body)
  | status == 200 = do
      observation <-
        first
          AuthorityControlResponseInvalid
          (decodeControlPlaneResponse authorityControlMaximumResponseBytes (LazyByteString.fromStrict body))
      if providerAdmissionRecoveryRequestDigest observation == cascadeAuditRecoveryRequestDigest binding
        then do
          first
            AuthorityControlRecoveryObservationInvalid
            (validateProviderAdmissionRecoveryObservation binding observation)
          Right observation
        else Left AuthorityControlRecoveryResponseMismatch
  | otherwise = do
      summary <- decodeAuthorityControlTextBody body
      if status == 409
        then Left (AuthorityControlRefused summary)
        else Left (AuthorityControlHttpStatus status summary)
