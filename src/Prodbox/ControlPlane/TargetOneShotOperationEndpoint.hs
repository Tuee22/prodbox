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
  , targetOneShotOperationAuthenticatedHandler
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
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
  , TlsTargetVerifyResult (..)
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

data TargetOneShotOperationBoundary m = TargetOneShotOperationBoundary
  { runTargetOneShotOperation
      :: TargetWorkerOperationInput
      -> m (Either Text TargetWorkerOperationResult)
  , targetOneShotOperationBoundaryReadiness :: !RoleReadinessSource
  }

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
        Left err -> pure (tlsPrepareResponse (TlsTargetPrepareBadRequest err))
        Right () -> do
          result <- runTargetOneShotOperation boundary TargetWorkerTlsPrepareInput
          pure $ case result of
            Right (TargetWorkerTlsPreparedResult prepared) ->
              tlsPrepareResponse (TlsTargetPrepared prepared)
            _ -> operationUnavailable "tls-target-prepare"
      pure (Just response)
    TargetTlsRetain -> do
      response <- case decode body of
        Left err -> pure (tlsRetainResponse (TlsTargetRetainBadRequest err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsRetainInput request)
          pure $ case result of
            Right (TargetWorkerTlsRetainedResult receipt) ->
              tlsRetainResponse (TlsTargetRetained receipt)
            Right TargetWorkerTlsRetainMissingResult ->
              tlsRetainResponse TlsTargetRetainMissing
            _ -> operationUnavailable "tls-target-retain"
      pure (Just response)
    TargetTlsHomeWrap -> do
      response <- case decode body of
        Left err -> pure (tlsWrapResponse (TlsHomeWrapBadRequest err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsHomeWrapInput request)
          pure $ case result of
            Right (TargetWorkerTlsHomeWrappedResult wrapped) ->
              tlsWrapResponse (TlsHomeWrapped wrapped)
            _ -> operationUnavailable "tls-home-wrap"
      pure (Just response)
    TargetTlsHomeRewrap -> do
      response <- case decode body of
        Left err -> pure (tlsRewrapResponse (TlsHomeRewrapBadRequest err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsHomeRewrapInput request)
          pure $ case result of
            Right (TargetWorkerTlsHomeRewrappedResult envelope) ->
              tlsRewrapResponse (TlsHomeRewrapped envelope)
            _ -> operationUnavailable "tls-home-rewrap"
      pure (Just response)
    TargetTlsRestore -> do
      response <- case decode body of
        Left err -> pure (tlsRestoreResponse (TlsTargetRestoreBadRequest err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsRestoreInput request)
          pure $ case result of
            Right (TargetWorkerTlsRestoredResult receipt) ->
              tlsRestoreResponse (TlsTargetRestored receipt)
            _ -> operationUnavailable "tls-target-restore"
      pure (Just response)
    TargetTlsVerifySource -> do
      response <- case decode body of
        Left err -> pure (tlsVerifyResponse (TlsTargetVerifyBadRequest err))
        Right request -> do
          result <-
            runTargetOneShotOperation
              boundary
              (TargetWorkerTlsVerifyInput request)
          pure $ case result of
            Right (TargetWorkerTlsVerifiedResult receipt) ->
              tlsVerifyResponse (TlsTargetSourceVerified receipt)
            Right TargetWorkerTlsVerifyMissingResult ->
              tlsVerifyResponse TlsTargetVerifyMissing
            Right TargetWorkerTlsVerifyMismatchResult ->
              tlsVerifyResponse TlsTargetVerifyMismatch
            _ -> operationUnavailable "tls-target-verify"
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

tlsPrepareResponse :: TlsTargetPrepareResult -> (Int, ByteString)
tlsPrepareResponse result =
  (tlsTargetPrepareHttpStatus result, tlsTargetPrepareResponseBody result)

tlsRetainResponse :: TlsTargetRetainResult -> (Int, ByteString)
tlsRetainResponse result =
  (tlsTargetRetainHttpStatus result, tlsTargetRetainResponseBody result)

tlsWrapResponse :: TlsHomeWrapResult -> (Int, ByteString)
tlsWrapResponse result =
  (tlsHomeWrapHttpStatus result, tlsHomeWrapResponseBody result)

tlsRewrapResponse :: TlsHomeRewrapResult -> (Int, ByteString)
tlsRewrapResponse result =
  (tlsHomeRewrapHttpStatus result, tlsHomeRewrapResponseBody result)

tlsRestoreResponse :: TlsTargetRestoreResult -> (Int, ByteString)
tlsRestoreResponse result =
  (tlsTargetRestoreHttpStatus result, tlsTargetRestoreResponseBody result)

tlsVerifyResponse :: TlsTargetVerifyResult -> (Int, ByteString)
tlsVerifyResponse result =
  (tlsTargetVerifyHttpStatus result, tlsTargetVerifyResponseBody result)

operationUnavailable :: ByteString -> (Int, ByteString)
operationUnavailable label = (503, label <> ":one-shot-operation-unavailable")

custodyCommitStatus :: ChildCustodyCommitResponse -> Int
custodyCommitStatus response = case response of
  ChildCustodyCommitted {} -> 200
  ChildCustodyCommitRefused {} -> 409
  ChildCustodyCommitUnavailable {} -> 503

custodyPrepareStatus :: ChildRecoveryPrepareResponse -> Int
custodyPrepareStatus response = case response of
  ChildRecoveryPrepared {} -> 200
  ChildRecoveryPrepareRefused {} -> 409
  ChildRecoveryPrepareUnavailable {} -> 503

custodyObserveStatus :: ChildRecoveryObserveResponse -> Int
custodyObserveStatus response = case response of
  ChildRecoveryConsumptionObserved {} -> 200
  ChildRecoveryObserveRefused {} -> 409
  ChildRecoveryObserveUnavailable {} -> 503

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
