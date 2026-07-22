{-# LANGUAGE OverloadedStrings #-}

-- | Cycle-free composition from the bounded HTTP server to the typed Broker
-- engine.  'Engine' intentionally knows nothing about HTTP reply types;
-- 'Server' intentionally knows nothing about capability programs.
module Prodbox.Bootstrap.Broker.EngineAdapter
  ( engineBrokerInterpreter
  , runEngineBrokerRequest
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Prodbox.Bootstrap.Broker.Engine
  ( BrokerEngine
  , BrokerEngineError (..)
  , EngineBoundaryError (..)
  , SomeBrokerResponse
  , admitBrokerCall
  , decodeBrokerCall
  , encodeSomeBrokerResponse
  , executeBrokerCall
  , mkEngineExecutionContext
  , prepareBrokerCall
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerRoute
  , brokerRouteIsMutation
  , brokerRouteMethod
  , brokerRoutePath
  )
import Prodbox.Bootstrap.Broker.Server
  ( BrokerInterpreter (..)
  , BrokerReply
  , BrokerReplyStatus (..)
  , BrokerRequestBody
  , BrokerRequestContext (..)
  , failClosedBrokerInterpreter
  , mkBrokerReply
  , withBrokerRequestBody
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( StoreBoundaryError (..)
  )

engineBrokerInterpreter :: BrokerEngine IO -> BrokerInterpreter
engineBrokerInterpreter engine =
  BrokerInterpreter $ \context route body -> do
    outcome <- runEngineBrokerRequest engine context route body
    case outcome of
      Right response ->
        boundedReply
          context
          route
          body
          (if brokerRouteIsMutation route then BrokerReplyAccepted else BrokerReplyOk)
          (encodeSomeBrokerResponse response)
      Left failure ->
        let (status, responseBody) = engineErrorReply failure
         in boundedReply context route body status responseBody

runEngineBrokerRequest
  :: BrokerEngine IO
  -> BrokerRequestContext
  -> BrokerRoute
  -> Maybe BrokerRequestBody
  -> IO (Either BrokerEngineError SomeBrokerResponse)
runEngineBrokerRequest engine context route requestBody =
  case decodeBrokerCall
    (brokerRouteMethod route)
    (brokerRoutePath route)
    (requestBodyBytes requestBody) of
    Left failure -> pure (Left failure)
    Right decoded -> do
      prepared <- prepareBrokerCall engine decoded
      case prepared of
        Left failure -> pure (Left failure)
        Right preparedCall -> do
          admitted <- admitBrokerCall engine preparedCall
          case admitted of
            Left failure -> pure (Left failure)
            Right admittedCall ->
              executeBrokerCall
                engine
                (mkEngineExecutionContext (brokerRequestDeadline context))
                admittedCall

requestBodyBytes :: Maybe BrokerRequestBody -> ByteString
requestBodyBytes requestBody = case requestBody of
  Nothing -> ByteString.empty
  Just body -> withBrokerRequestBody body id

boundedReply
  :: BrokerRequestContext
  -> BrokerRoute
  -> Maybe BrokerRequestBody
  -> BrokerReplyStatus
  -> ByteString
  -> IO BrokerReply
boundedReply context route body status responseBody =
  case mkBrokerReply status responseBody of
    Right reply -> pure reply
    Left _ -> interpretBrokerRequest failClosedBrokerInterpreter context route body

engineErrorReply :: BrokerEngineError -> (BrokerReplyStatus, ByteString)
engineErrorReply failure = case failure of
  EngineUnknownRoute -> notFound
  EngineWrongMethod _ -> methodNotAllowed
  EngineBodyRequired _ -> badRequest
  EngineBodyForbidden _ -> badRequest
  EngineProtocolRefused _ -> badRequest
  EngineProgramEvidenceRefused boundaryFailure -> boundaryReply boundaryFailure
  EngineEvidenceGenerationMismatch _ -> conflict
  EngineCapabilityAdmissionRefused boundaryFailure -> boundaryReply boundaryFailure
  EngineCapabilityExecutionRefused boundaryFailure -> boundaryReply boundaryFailure
  EngineFenceAcquireRefused boundaryFailure -> boundaryReply boundaryFailure
  EngineFenceBindingMismatch -> conflict
  EngineFenceUseRefused _ -> conflict
  EngineSecretWorkerRefused _ -> conflict
  EngineSecretWorkerBoundaryUnavailable ->
    (BrokerReplyServiceUnavailable, "{\"status\":\"worker-boundary-unavailable\"}")
  EngineSecretWorkerCallMismatch -> conflict
  EnginePgpBoundaryRefused _ -> conflict
  EnginePgpBoundaryUnavailable ->
    (BrokerReplyServiceUnavailable, "{\"status\":\"pgp-boundary-unavailable\"}")
  EngineGeneratedRootScopeLost -> conflict
  EnginePhysicalCallRefused boundaryFailure -> boundaryReply boundaryFailure
  EngineStoreRefused storeFailure -> storeReply storeFailure
  EngineStoreReadBackMismatch -> conflict
  EngineStoreVersionConflict -> conflict
  EngineCustodyTransitionRefused _ -> conflict
  EngineCustodyPlanLimitExceeded -> internalError
  EngineInitializationAmbiguous _ -> conflict
  EngineMutationReceiptMismatch -> conflict
  EngineResponseEvidenceMismatch _ -> conflict
 where
  badRequest =
    (BrokerReplyBadRequest, "{\"status\":\"request-refused\"}")
  notFound =
    (BrokerReplyNotFound, "{\"status\":\"route-not-found\"}")
  methodNotAllowed =
    (BrokerReplyMethodNotAllowed, "{\"status\":\"method-not-allowed\"}")
  conflict =
    (BrokerReplyConflict, "{\"status\":\"state-conflict\"}")
  internalError =
    (BrokerReplyInternalError, "{\"status\":\"engine-limit-refused\"}")

boundaryReply :: EngineBoundaryError -> (BrokerReplyStatus, ByteString)
boundaryReply failure = case failure of
  EngineBoundaryUnavailable _ ->
    (BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
  EngineBoundaryRefused _ ->
    (BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
  EngineBoundaryAmbiguous _ ->
    (BrokerReplyGatewayTimeout, "{\"status\":\"boundary-ambiguous\"}")

storeReply :: StoreBoundaryError -> (BrokerReplyStatus, ByteString)
storeReply failure = case failure of
  BootstrapStoreUnavailable ->
    (BrokerReplyServiceUnavailable, "{\"status\":\"store-unavailable\"}")
  BootstrapStoreCorrupt ->
    (BrokerReplyConflict, "{\"status\":\"store-corrupt\"}")
  BootstrapStoreBindingMismatch ->
    (BrokerReplyConflict, "{\"status\":\"store-binding-mismatch\"}")
  BootstrapStoreVersionConflict ->
    (BrokerReplyConflict, "{\"status\":\"store-version-conflict\"}")
  BootstrapStoreReadBackMismatch ->
    (BrokerReplyConflict, "{\"status\":\"store-read-back-mismatch\"}")
