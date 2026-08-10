{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority endpoint for issuing one exact
-- Target-worker intent from an already-prepared retained outbox entry.
module Prodbox.ControlPlane.TargetIntentAuthorityEndpoint
  ( TargetIntentIssueWireRequest (..)
  , TargetExecutionPermitWireRequest (..)
  , TargetIntentIssueResponse (..)
  , targetIntentIssueResponseMaximumBytes
  , targetIntentIssueAuthenticatedHandler
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerService)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  , verifiedCallerSlotPrincipal
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleTargetIntentIssue)
  )
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , mkServiceSessionBinding
  )
import Prodbox.ControlPlane.TargetIntentAuthority
  ( IssuedTargetIntent
  , TargetIntentIssueError (..)
  , TargetIntentIssueRequest (..)
  , TargetIntentIssuerBoundary (..)
  , issueTargetCommittedIntent
  , issuedTargetAcceptedAuthority
  , issuedTargetSignedIntent
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetFederationCustody, TargetPublicEdgeTls)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , SignedTargetCommittedIntent
  , TargetAgentRolloutEvidence
  , TargetCommittedIntentSpec (..)
  , decodeSignedTargetCommittedIntent
  , encodeAcceptedTargetAuthority
  , encodeSignedTargetCommittedIntent
  , mkTargetAgentIdentity
  , mkTargetAgentRolloutEvidence
  , signedTargetCommittedIntentSpec
  , signedTargetCommittedIntentTarget
  , targetCommittedIntentMaximumEncodedBytes
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( RawTargetWorkerPodObservation
  , TargetWorkerAttestation
  , TargetWorkerIngressSchema
  , attestTargetWorkerPod
  , mkTargetWorkerImageDigest
  , prepareTargetWorkerIntent
  , targetWorkerAttestedIntent
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( encodeTargetWorkerExecutionPermit
  , issueTargetWorkerExecutionPermit
  , targetWorkerExecutionPermitMatchesObservation
  , verifyTargetWorkerExecutionPermit
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkCredentialGeneration
  , mkTargetValueDigest
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

data TargetIntentIssueWireRequest = TargetIntentIssueWireRequest
  { targetIntentIssueWireTarget :: !TargetSecretId
  , targetIntentIssueWireAgentIdentity :: !Text
  , targetIntentIssueWireGeneration :: !Natural
  , targetIntentIssueWireReceiptDigest :: !Text
  , targetIntentIssueWireOperationId :: !Text
  , targetIntentIssueWireActionIndex :: !Natural
  , targetIntentIssueWireIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetExecutionPermitWireRequest = TargetExecutionPermitWireRequest
  { targetExecutionPermitWireSignedIntent :: !ByteString
  , targetExecutionPermitWireSchema :: !TargetWorkerIngressSchema
  , targetExecutionPermitWireImageDigest :: !Text
  , targetExecutionPermitWireAgentIdentity :: !Text
  , targetExecutionPermitWireDeploymentUid :: !Text
  , targetExecutionPermitWireDeploymentGeneration :: !Natural
  , targetExecutionPermitWireObservedDeploymentGeneration :: !Natural
  , targetExecutionPermitWireObservedRolloutDigest :: !Text
  , targetExecutionPermitWireObservation :: !RawTargetWorkerPodObservation
  , targetExecutionPermitWireSessionRole :: !Text
  , targetExecutionPermitWireSessionOperationId :: !Text
  , targetExecutionPermitWireSessionAttemptId :: !Text
  , targetExecutionPermitWireSessionFence :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetIntentIssueResponse
  = TargetIntentIssueAuthorized
      { targetIntentIssueSignedBytes :: !ByteString
      , targetIntentIssueAcceptedAuthorityBytes :: !ByteString
      }
  | TargetExecutionPermitAuthorized !ByteString
  | TargetIntentIssueRefused !Text
  | TargetIntentIssueUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

targetIntentIssueResponseMaximumBytes :: Int
targetIntentIssueResponseMaximumBytes = 96 * 1024

targetIntentIssueAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetIntentIssuerBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
targetIntentIssueAuthenticatedHandler maximumBytes boundary inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handleTargetIntentIssue maximumBytes boundary inner
    }

handleTargetIntentIssue
  :: (Monad m)
  => Int
  -> TargetIntentIssuerBoundary m
  -> AuthenticatedRoleHandler m
  -> VerifiedCallerSlot
  -> ControlPlaneRoute
  -> ByteString
  -> m (Maybe (ReplyStatus, ByteString))
handleTargetIntentIssue maximumBytes boundary inner caller route body = case route of
  LifecycleTargetIntentIssue -> do
    response <-
      case ( decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body)
               :: Either ControlPlaneRequestCodecError TargetIntentIssueWireRequest
           ) of
        Right wire -> case requestFromWire wire of
          Left detail -> pure (TargetIntentIssueRefused detail)
          Right request ->
            case authorizeTargetIntentCaller caller (targetIntentIssueTarget request) of
              Left detail -> pure (TargetIntentIssueRefused detail)
              Right () ->
                responseFromResult <$> issueTargetCommittedIntent boundary request
        Left _ ->
          case ( decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body)
                   :: Either ControlPlaneRequestCodecError TargetExecutionPermitWireRequest
               ) of
            Left _ -> pure (TargetIntentIssueRefused "request-codec-rejected")
            Right wire -> permitResponse caller boundary wire
    pure
      ( Just
          (targetIntentIssueResponseStatus response, responseBody response)
      )
  _ -> authenticatedHandlerHandle inner caller route body

requestFromWire
  :: TargetIntentIssueWireRequest
  -> Either Text TargetIntentIssueRequest
requestFromWire wire = do
  agentIdentity <-
    either
      (const (Left "target-agent-identity-invalid"))
      Right
      (mkTargetAgentIdentity (targetIntentIssueWireAgentIdentity wire))
  generation <-
    either
      (const (Left "generation-invalid"))
      Right
      (mkCredentialGeneration (targetIntentIssueWireGeneration wire))
  digest <-
    either
      (const (Left "receipt-digest-invalid"))
      Right
      (mkTargetValueDigest (targetIntentIssueWireReceiptDigest wire))
  Right
    TargetIntentIssueRequest
      { targetIntentIssueTarget = targetIntentIssueWireTarget wire
      , targetIntentIssueExpectedAgentIdentity = agentIdentity
      , targetIntentIssueExpectedGeneration = generation
      , targetIntentIssueExpectedReceiptDigest = digest
      , targetIntentIssueOperationId = targetIntentIssueWireOperationId wire
      , targetIntentIssueActionIndex = targetIntentIssueWireActionIndex wire
      , targetIntentIssueIdempotencyKey = targetIntentIssueWireIdempotencyKey wire
      }

permitResponse
  :: (Monad m)
  => VerifiedCallerSlot
  -> TargetIntentIssuerBoundary m
  -> TargetExecutionPermitWireRequest
  -> m TargetIntentIssueResponse
permitResponse caller boundary wire =
  case decodeAndReissueRequest wire of
    Left detail -> pure (TargetIntentIssueRefused detail)
    Right (signed, request) ->
      case authorizeTargetIntentCaller caller (targetIntentIssueTarget request) of
        Left detail -> pure (TargetIntentIssueRefused detail)
        Right () -> do
          reissued <- issueTargetCommittedIntent boundary request
          case reissued of
            Left err -> pure (permitIssueFailure err)
            Right issued
              | encodeSignedTargetCommittedIntent (issuedTargetSignedIntent issued)
                  /= targetExecutionPermitWireSignedIntent wire ->
                  pure (TargetIntentIssueRefused "initial-intent-no-longer-current")
              | otherwise -> do
                  nowResult <- readTargetIntentAuthorityTime boundary
                  case nowResult of
                    Left _ -> pure (TargetIntentIssueUnavailable "authority-clock-unavailable")
                    Right now ->
                      case buildObservedPermitRequest now signed (issuedTargetAcceptedAuthority issued) wire of
                        Left detail -> pure (TargetIntentIssueRefused detail)
                        Right (rollout, attestation, sessionBinding) -> do
                          permitted <-
                            issueTargetWorkerExecutionPermit
                              (targetIntentAuthoritySigner boundary)
                              (issuedTargetAcceptedAuthority issued)
                              rollout
                              attestation
                              sessionBinding
                          pure $ case permitted of
                            Left _ -> TargetIntentIssueUnavailable "execution-permit-signer-unavailable"
                            Right permit ->
                              case verifyTargetWorkerExecutionPermit
                                (issuedTargetAcceptedAuthority issued)
                                now
                                (targetWorkerAttestedIntent attestation)
                                permit of
                                Left _ -> TargetIntentIssueRefused "execution-permit-verification-failed"
                                Right verified
                                  | targetWorkerExecutionPermitMatchesObservation
                                      rollout
                                      attestation
                                      sessionBinding
                                      verified ->
                                      TargetExecutionPermitAuthorized
                                        (encodeTargetWorkerExecutionPermit permit)
                                  | otherwise ->
                                      TargetIntentIssueRefused "execution-permit-binding-mismatch"

-- | The standing Target Agent may ask the Authority only for one-shot
-- operation coordinates. Conversely, operator, harness, and Authority callers
-- may issue ordinary retained-material intents but cannot impersonate the
-- Target Agent's operation coordinator.
authorizeTargetIntentCaller
  :: VerifiedCallerSlot
  -> TargetSecretId
  -> Either Text ()
authorizeTargetIntentCaller caller target =
  case (verifiedCallerSlotPrincipal caller, isOperationTarget target) of
    (CallerService TargetSecretAgentRuntime, True) -> Right ()
    (CallerService TargetSecretAgentRuntime, False) ->
      Left "target-agent-material-intent-forbidden"
    (_, True) -> Left "operation-intent-requires-target-agent"
    (_, False) -> Right ()
 where
  isOperationTarget candidate = case candidate of
    TargetPublicEdgeTls -> True
    TargetFederationCustody -> True
    _ -> False

decodeAndReissueRequest
  :: TargetExecutionPermitWireRequest
  -> Either Text (SignedTargetCommittedIntent, TargetIntentIssueRequest)
decodeAndReissueRequest wire = do
  signed <-
    either
      (const (Left "initial-intent-invalid"))
      Right
      ( decodeSignedTargetCommittedIntent
          targetCommittedIntentMaximumEncodedBytes
          (targetExecutionPermitWireSignedIntent wire)
      )
  let spec = signedTargetCommittedIntentSpec signed
  pure
    ( signed
    , TargetIntentIssueRequest
        { targetIntentIssueTarget = signedTargetCommittedIntentTarget signed
        , targetIntentIssueExpectedAgentIdentity = targetIntentAgentIdentity spec
        , targetIntentIssueExpectedGeneration = targetIntentGeneration spec
        , targetIntentIssueExpectedReceiptDigest = targetIntentCommitReceiptDigest spec
        , targetIntentIssueOperationId = targetIntentOperationId spec
        , targetIntentIssueActionIndex = targetIntentActionIndex spec
        , targetIntentIssueIdempotencyKey = targetIntentIdempotencyKey spec
        }
    )

buildObservedPermitRequest
  :: AuthorityTime
  -> SignedTargetCommittedIntent
  -> AcceptedTargetAuthority
  -> TargetExecutionPermitWireRequest
  -> Either
       Text
       ( TargetAgentRolloutEvidence
       , TargetWorkerAttestation
       , ServiceSessionBinding
       )
buildObservedPermitRequest now signed accepted wire = do
  let spec = signedTargetCommittedIntentSpec signed
      agentIdentity = targetIntentAgentIdentity spec
      target = signedTargetCommittedIntentTarget signed
  wireAgent <-
    either
      (const (Left "execution-agent-identity-invalid"))
      Right
      (mkTargetAgentIdentity (targetExecutionPermitWireAgentIdentity wire))
  if wireAgent == agentIdentity
    then Right ()
    else Left "execution-agent-identity-mismatch"
  rollout <-
    either
      (const (Left "execution-agent-rollout-invalid"))
      Right
      ( mkTargetAgentRolloutEvidence
          wireAgent
          (targetExecutionPermitWireDeploymentUid wire)
          (targetExecutionPermitWireDeploymentGeneration wire)
          (targetExecutionPermitWireObservedDeploymentGeneration wire)
          (targetExecutionPermitWireObservedRolloutDigest wire)
      )
  image <-
    either
      (const (Left "execution-worker-image-invalid"))
      Right
      (mkTargetWorkerImageDigest (targetExecutionPermitWireImageDigest wire))
  intent <-
    either
      (const (Left "initial-intent-verification-failed"))
      Right
      ( prepareTargetWorkerIntent
          accepted
          now
          agentIdentity
          target
          (targetExecutionPermitWireSchema wire)
          image
          (targetExecutionPermitWireSignedIntent wire)
      )
  attestation <-
    either
      (const (Left "execution-observation-invalid"))
      Right
      (attestTargetWorkerPod now intent (targetExecutionPermitWireObservation wire))
  sessionBinding <-
    either
      (const (Left "execution-session-binding-invalid"))
      Right
      ( mkServiceSessionBinding
          (targetExecutionPermitWireSessionRole wire)
          (targetExecutionPermitWireSessionOperationId wire)
          (targetExecutionPermitWireSessionAttemptId wire)
          (targetExecutionPermitWireSessionFence wire)
      )
  Right (rollout, attestation, sessionBinding)

permitIssueFailure :: TargetIntentIssueError -> TargetIntentIssueResponse
permitIssueFailure err = case responseFromResult (Left err) of
  TargetIntentIssueAuthorized {} -> TargetIntentIssueRefused "initial-intent-reissue-invalid"
  TargetExecutionPermitAuthorized _ -> TargetIntentIssueRefused "initial-intent-reissue-invalid"
  response -> response

responseFromResult
  :: Either TargetIntentIssueError IssuedTargetIntent
  -> TargetIntentIssueResponse
responseFromResult result = case result of
  Right issued ->
    TargetIntentIssueAuthorized
      { targetIntentIssueSignedBytes =
          encodeSignedTargetCommittedIntent (issuedTargetSignedIntent issued)
      , targetIntentIssueAcceptedAuthorityBytes =
          encodeAcceptedTargetAuthority (issuedTargetAcceptedAuthority issued)
      }
  Left err -> case err of
    TargetIntentIssuePreparedIntentUnavailable _ ->
      TargetIntentIssueUnavailable "prepared-intent-unavailable"
    TargetIntentIssueClockUnavailable _ ->
      TargetIntentIssueUnavailable "authority-clock-unavailable"
    TargetIntentIssueEpochUnavailable _ ->
      TargetIntentIssueUnavailable "authority-epoch-unavailable"
    TargetIntentIssueSignerUnavailable _ ->
      TargetIntentIssueUnavailable "authority-signer-unavailable"
    TargetIntentIssueTrustInstallUnavailable _ ->
      TargetIntentIssueUnavailable "target-trust-install-unavailable"
    TargetIntentIssueSignerGenerationChanged _ _ ->
      TargetIntentIssueRefused "authority-signer-rotated"
    TargetIntentIssueTargetUnregistered _ ->
      TargetIntentIssueRefused "target-unregistered"
    TargetIntentIssueTargetMismatch _ _ ->
      TargetIntentIssueRefused "target-mismatch"
    TargetIntentIssueAgentIdentityMismatch _ _ ->
      TargetIntentIssueRefused "target-agent-identity-mismatch"
    TargetIntentIssueNotPrepared ->
      TargetIntentIssueRefused "intent-not-prepared"
    TargetIntentIssueGenerationMismatch ->
      TargetIntentIssueRefused "generation-mismatch"
    TargetIntentIssueReceiptDigestMismatch ->
      TargetIntentIssueRefused "receipt-digest-mismatch"
    TargetIntentIssueDeadlineReached ->
      TargetIntentIssueRefused "intent-deadline-reached"
    TargetIntentIssueValueInvalid _ ->
      TargetIntentIssueRefused "intent-value-invalid"
    TargetIntentIssueSignatureInvalid _ ->
      TargetIntentIssueRefused "intent-signature-invalid"
    TargetIntentIssueTrustReadBackMismatch ->
      TargetIntentIssueRefused "target-trust-read-back-mismatch"

targetIntentIssueResponseStatus :: TargetIntentIssueResponse -> ReplyStatus
targetIntentIssueResponseStatus response = case response of
  TargetIntentIssueAuthorized {} -> ReplyOk
  TargetExecutionPermitAuthorized _ -> ReplyOk
  TargetIntentIssueRefused _ -> ReplyConflict
  TargetIntentIssueUnavailable _ -> ReplyServiceUnavailable

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
