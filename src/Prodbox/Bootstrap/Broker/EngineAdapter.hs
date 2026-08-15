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
import Data.List (intercalate)
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
  , someBrokerResponseIsUnreadyProbe
  )
import Prodbox.Bootstrap.Broker.EngineSecretWorker
  ( EngineSecretWorkerError (..)
  , secretWorkerBindingFieldName
  , secretWorkerBindingSiteName
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
import Prodbox.CLI.Output (writeDiagnosticLine)

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
          (replyStatusFor route response)
          (encodeSomeBrokerResponse response)
      Left failure -> do
        -- Sprint 2.46: name the refusal server-side before it becomes a reply.
        -- Five distinct engine errors collapse to one wire body, so without
        -- this the operator cannot tell which decision refused.
        writeDiagnosticLine (brokerEngineErrorDiagnostic route failure)
        let (status, responseBody) = engineErrorReply failure
         in boundedReply context route body status responseBody

-- | Sprint 2.46: a secret-safe, total name for a refusal.
--
-- __This deliberately renders the constructor, not the carried detail.__ The
-- detail on a boundary refusal is frequently @Text.pack . show@ over a typed
-- error, and these are Vault bootstrap paths; a @show@ that one day carries
-- token or share material would publish it to the pod log, which is the exact
-- class [vault_doctrine.md § 20](../../../documents/engineering/vault_doctrine.md)
-- forbids. Constructor names are a closed, authored, finite set and cannot
-- carry a secret.
--
-- __The bound, therefore:__ this answers /which decision refused/, not /why/.
-- That is the question that was unanswerable — `boundary-refused` on the wire
-- is produced by five different engine errors — and it is answered without
-- taking on a leak risk to do it. Widening to the detail needs a redaction
-- analysis of every producer, which is its own work.
brokerEngineErrorDiagnostic :: BrokerRoute -> BrokerEngineError -> String
brokerEngineErrorDiagnostic route failure =
  "bootstrap-broker refused "
    ++ brokerRoutePath route
    ++ ": "
    ++ brokerEngineErrorName failure
    ++ boundaryDetailClass failure
 where
  boundaryDetailClass value = case value of
    EngineProgramEvidenceRefused boundary -> " (" ++ boundaryName boundary ++ ")"
    EngineCapabilityAdmissionRefused boundary -> " (" ++ boundaryName boundary ++ ")"
    EngineCapabilityExecutionRefused boundary -> " (" ++ boundaryName boundary ++ ")"
    EngineFenceAcquireRefused boundary -> " (" ++ boundaryName boundary ++ ")"
    EnginePhysicalCallRefused boundary -> " (" ++ boundaryName boundary ++ ")"
    _ -> ""
  boundaryName boundary = case boundary of
    EngineBoundaryUnavailable _ -> "boundary-unavailable"
    EngineBoundaryRefused _ -> "boundary-refused"
    EngineBoundaryAmbiguous _ -> "boundary-ambiguous"

-- | The closed constructor set, spelled out so a new engine error is a compile
-- error here rather than an unnamed refusal in production.
brokerEngineErrorName :: BrokerEngineError -> String
brokerEngineErrorName failure = case failure of
  EngineUnknownRoute -> "EngineUnknownRoute"
  EngineWrongMethod _ -> "EngineWrongMethod"
  EngineBodyRequired _ -> "EngineBodyRequired"
  EngineBodyForbidden _ -> "EngineBodyForbidden"
  EngineProtocolRefused _ -> "EngineProtocolRefused"
  EngineProgramEvidenceRefused _ -> "EngineProgramEvidenceRefused"
  EngineEvidenceGenerationMismatch _ -> "EngineEvidenceGenerationMismatch"
  EngineCapabilityAdmissionRefused _ -> "EngineCapabilityAdmissionRefused"
  EngineCapabilityExecutionRefused _ -> "EngineCapabilityExecutionRefused"
  EngineFenceAcquireRefused _ -> "EngineFenceAcquireRefused"
  EngineFenceBindingMismatch -> "EngineFenceBindingMismatch"
  EngineFenceUseRefused _ -> "EngineFenceUseRefused"
  EngineSecretWorkerRefused nested ->
    "EngineSecretWorkerRefused/" ++ engineSecretWorkerErrorName nested
  EngineSecretWorkerBoundaryUnavailable -> "EngineSecretWorkerBoundaryUnavailable"
  EngineSecretWorkerCallMismatch -> "EngineSecretWorkerCallMismatch"
  EnginePgpBoundaryRefused _ -> "EnginePgpBoundaryRefused"
  EnginePgpBoundaryUnavailable -> "EnginePgpBoundaryUnavailable"
  EngineGeneratedRootScopeLost -> "EngineGeneratedRootScopeLost"
  EnginePhysicalCallRefused _ -> "EnginePhysicalCallRefused"
  EngineStoreRefused _ -> "EngineStoreRefused"
  EngineStoreReadBackMismatch -> "EngineStoreReadBackMismatch"
  EngineStoreVersionConflict -> "EngineStoreVersionConflict"
  EngineCustodyTransitionRefused _ -> "EngineCustodyTransitionRefused"
  EngineCustodyPlanLimitExceeded -> "EngineCustodyPlanLimitExceeded"
  EngineInitializationAmbiguous _ -> "EngineInitializationAmbiguous"
  EngineMutationReceiptMismatch -> "EngineMutationReceiptMismatch"
  EngineResponseEvidenceMismatch _ -> "EngineResponseEvidenceMismatch"

-- | Sprint 2.49: the same closed-constructor rule, one level deeper.
--
-- `EngineSecretWorkerRefused` carries a twenty-constructor
-- 'EngineSecretWorkerError' and named none of it, so a permit deadline that
-- elapsed, a checkpoint read-back mismatch, an attestation refusal, and a
-- cleanup refusal all reached the operator as the single word
-- @EngineSecretWorkerRefused@. That is the widest collapse this surface had
-- left, and it is the fourth of this shape found in one session — after the
-- five acquire refusals (2.46), the six Lease refusals (2.47), the status code
-- inside the non-success arm (2.48), and the attestation candidate list (2.49,
-- host side).
--
-- Constructor names only, on the rule this module already applies: several of
-- these payloads carry durable bindings and nested refusals, and a name
-- distinguishes the twenty causes without publishing any of them.
engineSecretWorkerErrorName :: EngineSecretWorkerError boundaryError -> String
engineSecretWorkerErrorName failure = case failure of
  EngineSecretWorkerBoundaryRefused _ -> "BoundaryRefused"
  EngineSecretWorkerStoreRefused _ -> "StoreRefused"
  -- Sprint 2.50: five sites, one word. The site says which comparison failed
  -- and the fields say what disagreed; both are secret-free labels.
  EngineSecretWorkerStoredRequestBindingMismatch site fields ->
    "StoredRequestBindingMismatch/"
      ++ secretWorkerBindingSiteName site
      ++ "["
      ++ intercalate "," (map secretWorkerBindingFieldName fields)
      ++ "]"
  EngineSecretWorkerCheckpointPermitMutationMismatch _ _ ->
    "CheckpointPermitMutationMismatch"
  EngineSecretWorkerCheckpointPermitFenceMismatch -> "CheckpointPermitFenceMismatch"
  EngineSecretWorkerCheckpointPermitDeadlineElapsed -> "CheckpointPermitDeadlineElapsed"
  EngineSecretWorkerCheckpointWriteConflict -> "CheckpointWriteConflict"
  EngineSecretWorkerCheckpointWriteMismatch -> "CheckpointWriteMismatch"
  EngineSecretWorkerCheckpointReadBackMismatch -> "CheckpointReadBackMismatch"
  EngineSecretWorkerCheckpointResultMissing -> "CheckpointResultMissing"
  EngineSecretWorkerAuthoritativeCheckpointMissing -> "AuthoritativeCheckpointMissing"
  EngineSecretWorkerAuthoritativeResultMismatch -> "AuthoritativeResultMismatch"
  EngineSecretWorkerRecoveryRefused _ -> "RecoveryRefused"
  EngineSecretWorkerRecoveryDestroyedAndRefused _ -> "RecoveryDestroyedAndRefused"
  EngineSecretWorkerRecoveryDecisionUnexpected _ -> "RecoveryDecisionUnexpected"
  EngineSecretWorkerRepromptWasNotFresh -> "RepromptWasNotFresh"
  EngineSecretWorkerAttestationRefused _ -> "AttestationRefused"
  EngineSecretWorkerEffectRefused _ -> "EffectRefused"
  EngineSecretWorkerReceiptRefused _ -> "ReceiptRefused"
  EngineSecretWorkerCleanupRefused _ -> "CleanupRefused"

-- | The reply status for a successfully interpreted call.
--
-- A readiness projection that is not ready answers 503 so the chart's
-- @curl --fail@ probe fails on the verdict rather than on a timeout. The body
-- still carries the full state, so the reason survives the status.
replyStatusFor :: BrokerRoute -> SomeBrokerResponse -> BrokerReplyStatus
replyStatusFor route response
  | brokerRouteIsMutation route = BrokerReplyAccepted
  | someBrokerResponseIsUnreadyProbe response = BrokerReplyServiceUnavailable
  | otherwise = BrokerReplyOk

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
