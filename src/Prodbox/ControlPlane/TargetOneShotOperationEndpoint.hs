{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Arm-specific standing Target Agent endpoints whose effects are executed
-- only by an attested one-shot Target worker. The standing process decodes the
-- closed request, coordinates an exact worker operation, and returns only the
-- corresponding typed result; it never constructs TLS or custody production
-- capabilities itself.
module Prodbox.ControlPlane.TargetOneShotOperationEndpoint
  ( TargetOneShotOperationBoundary (..)
  , TlsTargetAgentPlainResponseCause (..)
  , TlsTargetAgentPlainResponseObservation (..)
  , allTlsTargetAgentPlainResponseCauses
  , tlsTargetAgentPlainResponse
  , classifyTlsTargetAgentPlainResponse
  , renderTlsTargetAgentPlainResponseCause
  , targetOneShotOperationAuthenticatedHandler
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.BootstrapCustodyEndpoint
  ( ChildCustodyCommitRequest (..)
  , ChildCustodyCommitResponse (..)
  , ChildRecoveryObserveMode (..)
  , ChildRecoveryObserveRequest (..)
  , ChildRecoveryObserveResponse (..)
  , ChildRecoveryPrepareRequest (..)
  , ChildRecoveryPrepareResponse (..)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , layerRoleReadinessSource
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerOperationResult (..)
  )
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
  ( TargetWorkerOperationInput (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsHomeRewrapResult (..)
  , TlsHomeWrapResult (..)
  , TlsTargetPrepareResult (..)
  , TlsTargetRestoreResult (..)
  , TlsTargetRetainResult (..)
  , TlsTargetVerifyMismatchCause
  , TlsTargetVerifyResult (..)
  , renderTlsTargetVerifyMismatchCause
  , tlsHomeRewrapHttpStatus
  , tlsHomeRewrapResponseBody
  , tlsHomeWrapHttpStatus
  , tlsHomeWrapResponseBody
  , tlsTargetPrepareHttpStatus
  , tlsTargetPrepareResponseBody
  , tlsTargetRestoreHttpStatus
  , tlsTargetRestoreResponseBody
  , tlsTargetRetainHttpStatus
  , tlsTargetRetainResponseBody
  , tlsTargetVerifyHttpStatus
  , tlsTargetVerifyResponseBody
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)

data TargetOneShotOperationBoundary m = TargetOneShotOperationBoundary
  { runTargetOneShotOperation
      :: TargetWorkerOperationInput
      -> m (Either Text TargetWorkerOperationResult)
  , targetOneShotOperationBoundaryReadiness :: !RoleReadinessSource
  }

-- | Every non-CBOR response pair authored by the standing Target Agent's TLS
-- routes. The cause is route-specific and value-free; worker, Secret, Vault,
-- and request details never enter this projection.
data TlsTargetAgentPlainResponseCause
  = TlsTargetPrepareRequestRefused !ControlPlaneRequestCodecError
  | TlsTargetPrepareOneShotUnavailable
  | TlsTargetRetainRequestRefused !ControlPlaneRequestCodecError
  | TlsTargetRetainMissingResponse
  | TlsTargetRetainOneShotUnavailable
  | TlsHomeWrapRequestRefused !ControlPlaneRequestCodecError
  | TlsHomeWrapOneShotUnavailable
  | TlsHomeRewrapRequestRefused !ControlPlaneRequestCodecError
  | TlsHomeRewrapOneShotUnavailable
  | TlsTargetRestoreRequestRefused !ControlPlaneRequestCodecError
  | TlsTargetRestoreOneShotUnavailable
  | TlsTargetVerifyRequestRefused !ControlPlaneRequestCodecError
  | TlsTargetVerifyMissingResponse
  | TlsTargetVerifyMismatchResponse !TlsTargetVerifyMismatchCause
  | TlsTargetVerifyOneShotUnavailable
  | TlsHomeRewrapCiphertextAuthenticationFailedResponse
  deriving stock (Eq, Show)

data TlsTargetAgentPlainResponseObservation
  = TlsTargetAgentPlainResponseKnown !TlsTargetAgentPlainResponseCause
  | TlsTargetAgentPlainResponseOther
  deriving stock (Eq, Show)

allTlsTargetAgentPlainResponseCauses :: [TlsTargetAgentPlainResponseCause]
allTlsTargetAgentPlainResponseCauses =
  (TlsTargetPrepareRequestRefused <$> allCodecErrors)
    <> [TlsTargetPrepareOneShotUnavailable]
    <> (TlsTargetRetainRequestRefused <$> allCodecErrors)
    <> [TlsTargetRetainMissingResponse, TlsTargetRetainOneShotUnavailable]
    <> (TlsHomeWrapRequestRefused <$> allCodecErrors)
    <> [TlsHomeWrapOneShotUnavailable]
    <> (TlsHomeRewrapRequestRefused <$> allCodecErrors)
    <> [TlsHomeRewrapOneShotUnavailable]
    <> (TlsTargetRestoreRequestRefused <$> allCodecErrors)
    <> [TlsTargetRestoreOneShotUnavailable]
    <> (TlsTargetVerifyRequestRefused <$> allCodecErrors)
    <> [TlsTargetVerifyMissingResponse]
    <> (TlsTargetVerifyMismatchResponse <$> [minBound .. maxBound])
    <> [TlsTargetVerifyOneShotUnavailable]
    <> [TlsHomeRewrapCiphertextAuthenticationFailedResponse]
 where
  allCodecErrors = [minBound .. maxBound]

-- | The single source of truth for the standing Target TLS endpoint's exact
-- plaintext response pairs.
tlsTargetAgentPlainResponse
  :: TlsTargetAgentPlainResponseCause -> (ReplyStatus, ByteString)
tlsTargetAgentPlainResponse cause = case cause of
  TlsTargetPrepareRequestRefused err ->
    tlsPrepareResponse (TlsTargetPrepareBadRequest err)
  TlsTargetPrepareOneShotUnavailable ->
    (ReplyServiceUnavailable, "tls-target-prepare:one-shot-operation-unavailable")
  TlsTargetRetainRequestRefused err ->
    tlsRetainResponse (TlsTargetRetainBadRequest err)
  TlsTargetRetainMissingResponse -> tlsRetainResponse TlsTargetRetainMissing
  TlsTargetRetainOneShotUnavailable ->
    (ReplyServiceUnavailable, "tls-target-retain:one-shot-operation-unavailable")
  TlsHomeWrapRequestRefused err -> tlsWrapResponse (TlsHomeWrapBadRequest err)
  TlsHomeWrapOneShotUnavailable ->
    (ReplyServiceUnavailable, "tls-home-wrap:one-shot-operation-unavailable")
  TlsHomeRewrapRequestRefused err -> tlsRewrapResponse (TlsHomeRewrapBadRequest err)
  TlsHomeRewrapOneShotUnavailable ->
    (ReplyServiceUnavailable, "tls-home-rewrap:one-shot-operation-unavailable")
  TlsTargetRestoreRequestRefused err ->
    tlsRestoreResponse (TlsTargetRestoreBadRequest err)
  TlsTargetRestoreOneShotUnavailable ->
    (ReplyServiceUnavailable, "tls-target-restore:one-shot-operation-unavailable")
  TlsTargetVerifyRequestRefused err ->
    tlsVerifyResponse (TlsTargetVerifyBadRequest err)
  TlsTargetVerifyMissingResponse -> tlsVerifyResponse TlsTargetVerifyMissing
  TlsTargetVerifyMismatchResponse mismatch ->
    tlsVerifyResponse (TlsTargetVerifyMismatch mismatch)
  TlsTargetVerifyOneShotUnavailable ->
    (ReplyServiceUnavailable, "tls-target-verify:one-shot-operation-unavailable")
  TlsHomeRewrapCiphertextAuthenticationFailedResponse ->
    tlsRewrapResponse TlsHomeRewrapCiphertextAuthenticationFailed

classifyTlsTargetAgentPlainResponse
  :: Int -> ByteString -> TlsTargetAgentPlainResponseObservation
classifyTlsTargetAgentPlainResponse status body =
  maybe
    TlsTargetAgentPlainResponseOther
    TlsTargetAgentPlainResponseKnown
    (find matches allTlsTargetAgentPlainResponseCauses)
 where
  matches cause =
    let (authoredStatus, authoredBody) = tlsTargetAgentPlainResponse cause
     in replyStatusCode authoredStatus == status && authoredBody == body

renderTlsTargetAgentPlainResponseCause :: TlsTargetAgentPlainResponseCause -> Text
renderTlsTargetAgentPlainResponseCause cause = case cause of
  TlsTargetPrepareRequestRefused err -> "prepare/request-refused/" <> codec err
  TlsTargetPrepareOneShotUnavailable -> "prepare/one-shot-operation-unavailable"
  TlsTargetRetainRequestRefused err -> "retain/request-refused/" <> codec err
  TlsTargetRetainMissingResponse -> "retain/missing"
  TlsTargetRetainOneShotUnavailable -> "retain/one-shot-operation-unavailable"
  TlsHomeWrapRequestRefused err -> "home-wrap/request-refused/" <> codec err
  TlsHomeWrapOneShotUnavailable -> "home-wrap/one-shot-operation-unavailable"
  TlsHomeRewrapRequestRefused err -> "home-rewrap/request-refused/" <> codec err
  TlsHomeRewrapOneShotUnavailable -> "home-rewrap/one-shot-operation-unavailable"
  TlsTargetRestoreRequestRefused err -> "restore/request-refused/" <> codec err
  TlsTargetRestoreOneShotUnavailable -> "restore/one-shot-operation-unavailable"
  TlsTargetVerifyRequestRefused err -> "verify/request-refused/" <> codec err
  TlsTargetVerifyMissingResponse -> "verify/missing"
  TlsTargetVerifyMismatchResponse mismatch ->
    "verify/mismatch/" <> renderTlsTargetVerifyMismatchCause mismatch
  TlsTargetVerifyOneShotUnavailable -> "verify/one-shot-operation-unavailable"
  TlsHomeRewrapCiphertextAuthenticationFailedResponse ->
    "home-rewrap/ciphertext-authentication-failed"
 where
  codec = controlPlaneRequestCodecToken

targetOneShotOperationAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetOneShotOperationBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
targetOneShotOperationAuthenticatedHandler maximumBytes boundary inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness =
        layerRoleReadinessSource
          (targetOneShotOperationBoundaryReadiness boundary)
          (authenticatedHandlerReadiness inner)
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    TargetTlsPrepareExchange -> do
      response <- case decode body of
        Left err -> pure (tlsTargetAgentPlainResponse (TlsTargetPrepareRequestRefused err))
        Right () -> do
          result <- runTargetOneShotOperation boundary TargetWorkerTlsPrepareInput
          pure $ case result of
            Right (TargetWorkerTlsPreparedResult prepared) ->
              tlsPrepareResponse (TlsTargetPrepared prepared)
            _ -> tlsTargetAgentPlainResponse TlsTargetPrepareOneShotUnavailable
      pure (Just response)
    TargetTlsRetain -> do
      response <- case decode body of
        Left err -> pure (tlsTargetAgentPlainResponse (TlsTargetRetainRequestRefused err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsRetainInput request)
          pure $ case result of
            Right (TargetWorkerTlsRetainedResult receipt) ->
              tlsRetainResponse (TlsTargetRetained receipt)
            Right TargetWorkerTlsRetainMissingResult ->
              tlsTargetAgentPlainResponse TlsTargetRetainMissingResponse
            _ -> tlsTargetAgentPlainResponse TlsTargetRetainOneShotUnavailable
      pure (Just response)
    TargetTlsHomeWrap -> do
      response <- case decode body of
        Left err -> pure (tlsTargetAgentPlainResponse (TlsHomeWrapRequestRefused err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsHomeWrapInput request)
          pure $ case result of
            Right (TargetWorkerTlsHomeWrappedResult wrapped) ->
              tlsWrapResponse (TlsHomeWrapped wrapped)
            _ -> tlsTargetAgentPlainResponse TlsHomeWrapOneShotUnavailable
      pure (Just response)
    TargetTlsHomeRewrap -> do
      response <- case decode body of
        Left err -> pure (tlsTargetAgentPlainResponse (TlsHomeRewrapRequestRefused err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsHomeRewrapInput request)
          pure $ case result of
            Right (TargetWorkerTlsHomeRewrappedResult envelope) ->
              tlsRewrapResponse (TlsHomeRewrapped envelope)
            Right TargetWorkerTlsHomeRewrapCiphertextAuthenticationFailedResult ->
              tlsTargetAgentPlainResponse
                TlsHomeRewrapCiphertextAuthenticationFailedResponse
            _ -> tlsTargetAgentPlainResponse TlsHomeRewrapOneShotUnavailable
      pure (Just response)
    TargetTlsRestore -> do
      response <- case decode body of
        Left err -> pure (tlsTargetAgentPlainResponse (TlsTargetRestoreRequestRefused err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsRestoreInput request)
          pure $ case result of
            Right (TargetWorkerTlsRestoredResult receipt) ->
              tlsRestoreResponse (TlsTargetRestored receipt)
            _ -> tlsTargetAgentPlainResponse TlsTargetRestoreOneShotUnavailable
      pure (Just response)
    TargetTlsVerifySource -> do
      response <- case decode body of
        Left err -> pure (tlsTargetAgentPlainResponse (TlsTargetVerifyRequestRefused err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsVerifyInput request)
          pure $ case result of
            Right (TargetWorkerTlsVerifiedResult receipt) ->
              tlsVerifyResponse (TlsTargetSourceVerified receipt)
            Right TargetWorkerTlsVerifyMissingResult ->
              tlsTargetAgentPlainResponse TlsTargetVerifyMissingResponse
            Right (TargetWorkerTlsVerifyMismatchResult cause) ->
              tlsTargetAgentPlainResponse (TlsTargetVerifyMismatchResponse cause)
            _ -> tlsTargetAgentPlainResponse TlsTargetVerifyOneShotUnavailable
      pure (Just response)
    TargetChildCustodyCommit -> do
      response <- case decodeText body of
        Left detail -> pure (ChildCustodyCommitRefused detail)
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerFederationCustodyCommitInput (childCustodyCommitIntent request))
          pure $ case result of
            Right (TargetWorkerFederationCustodyCommittedResult acknowledgement) ->
              ChildCustodyCommitted acknowledgement
            Left detail -> ChildCustodyCommitUnavailable detail
            Right _ -> ChildCustodyCommitUnavailable "operation-result-schema-mismatch"
      pure (Just (custodyCommitStatus response, responseBody response))
    TargetChildRecoveryPrepare -> do
      response <- case decodeText body of
        Left detail -> pure (ChildRecoveryPrepareRefused detail)
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              ( TargetWorkerFederationRecoveryPrepareInput
                  (childRecoveryPrepareBinding request)
                  (childRecoveryPrepareNonce request)
                  (childRecoveryPrepareAttestation request)
              )
          pure $ case result of
            Right (TargetWorkerFederationRecoveryPreparedResult delivery) ->
              ChildRecoveryPrepared delivery
            Left detail -> ChildRecoveryPrepareUnavailable detail
            Right _ -> ChildRecoveryPrepareUnavailable "operation-result-schema-mismatch"
      pure (Just (custodyPrepareStatus response, responseBody response))
    TargetChildRecoveryObserve -> do
      response <- case decodeText body of
        Left detail -> pure (ChildRecoveryObserveRefused detail)
        Right request -> do
          let operation = case childRecoveryObserveMode request of
                ObserveChildRecoveryConsumption ->
                  TargetWorkerFederationRecoveryObserveInput
                    (childRecoveryObserveDelivery request)
                CommitChildRecoveryConsumption ->
                  TargetWorkerFederationRecoveryCommitInput
                    (childRecoveryObserveDelivery request)
          result <- runTargetOneShotOperation boundary operation
          pure $ case result of
            Right (TargetWorkerFederationRecoveryObservedResult observation) ->
              ChildRecoveryConsumptionObserved observation
            Right (TargetWorkerFederationRecoveryCommittedResult observation) ->
              ChildRecoveryConsumptionObserved observation
            Left detail -> ChildRecoveryObserveUnavailable detail
            Right _ -> ChildRecoveryObserveUnavailable "operation-result-schema-mismatch"
      pure (Just (custodyObserveStatus response, responseBody response))
    _ -> authenticatedHandlerHandle inner caller route body

  decode
    :: (Serialise value)
    => ByteString
    -> Either ControlPlaneRequestCodecError value
  decode =
    decodeControlPlaneRequest maximumBytes . LazyByteString.fromStrict

  decodeText
    :: (Serialise value)
    => ByteString
    -> Either Text value
  decodeText =
    first (const "request-codec-rejected") . decode

tlsPrepareResponse :: TlsTargetPrepareResult -> (ReplyStatus, ByteString)
tlsPrepareResponse result =
  (tlsTargetPrepareHttpStatus result, tlsTargetPrepareResponseBody result)

tlsRetainResponse :: TlsTargetRetainResult -> (ReplyStatus, ByteString)
tlsRetainResponse result =
  (tlsTargetRetainHttpStatus result, tlsTargetRetainResponseBody result)

tlsWrapResponse :: TlsHomeWrapResult -> (ReplyStatus, ByteString)
tlsWrapResponse result =
  (tlsHomeWrapHttpStatus result, tlsHomeWrapResponseBody result)

tlsRewrapResponse :: TlsHomeRewrapResult -> (ReplyStatus, ByteString)
tlsRewrapResponse result =
  (tlsHomeRewrapHttpStatus result, tlsHomeRewrapResponseBody result)

tlsRestoreResponse :: TlsTargetRestoreResult -> (ReplyStatus, ByteString)
tlsRestoreResponse result =
  (tlsTargetRestoreHttpStatus result, tlsTargetRestoreResponseBody result)

tlsVerifyResponse :: TlsTargetVerifyResult -> (ReplyStatus, ByteString)
tlsVerifyResponse result =
  (tlsTargetVerifyHttpStatus result, tlsTargetVerifyResponseBody result)

custodyCommitStatus :: ChildCustodyCommitResponse -> ReplyStatus
custodyCommitStatus response = case response of
  ChildCustodyCommitted {} -> ReplyOk
  ChildCustodyCommitRefused {} -> ReplyConflict
  ChildCustodyCommitUnavailable {} -> ReplyServiceUnavailable

custodyPrepareStatus :: ChildRecoveryPrepareResponse -> ReplyStatus
custodyPrepareStatus response = case response of
  ChildRecoveryPrepared {} -> ReplyOk
  ChildRecoveryPrepareRefused {} -> ReplyConflict
  ChildRecoveryPrepareUnavailable {} -> ReplyServiceUnavailable

custodyObserveStatus :: ChildRecoveryObserveResponse -> ReplyStatus
custodyObserveStatus response = case response of
  ChildRecoveryConsumptionObserved {} -> ReplyOk
  ChildRecoveryObserveRefused {} -> ReplyConflict
  ChildRecoveryObserveUnavailable {} -> ReplyServiceUnavailable

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
