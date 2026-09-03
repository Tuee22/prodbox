{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client for the Lifecycle Authority Target-intent issuer.
module Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  , TargetIntentAuthorityClientError (..)
  , classifyTargetIntentAuthorityResponseDecodeFailure
  , targetIntentAuthorityClient
  , requestTargetCommittedIntent
  , requestTargetWorkerExecutionPermit
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation (..)
  , classifyAuthenticatedRolePlainResponse
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleTargetIntentIssueRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , serviceSessionBindingAttemptId
  , serviceSessionBindingFence
  , serviceSessionBindingOperationId
  , serviceSessionBindingRole
  )
import Prodbox.ControlPlane.TargetIntentAuthorityEndpoint
  ( TargetExecutionPermitWireRequest (..)
  , TargetIntentIssueResponse (..)
  , TargetIntentIssueWireRequest (..)
  , targetIntentIssueResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , targetSecretIdToken
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , SignedTargetCommittedIntent
  , TargetAgentIdentity
  , TargetAgentRolloutEvidence
  , acceptedTargetAuthorityMaximumEncodedBytes
  , decodeAcceptedTargetAuthority
  , decodeSignedTargetCommittedIntent
  , targetAgentIdentityText
  , targetAgentRolloutDeploymentGeneration
  , targetAgentRolloutDeploymentUid
  , targetAgentRolloutEvidenceIdentity
  , targetAgentRolloutObservedDigest
  , targetAgentRolloutObservedGeneration
  , targetCommittedIntentMaximumEncodedBytes
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( RawTargetWorkerPodObservation (..)
  , TargetWorkerAttestation
  , targetWorkerAttestedIntent
  , targetWorkerAttestedJobUid
  , targetWorkerAttestedPodName
  , targetWorkerAttestedPodUid
  , targetWorkerAttestedServiceAccountUid
  , targetWorkerImageDigestText
  , targetWorkerIntentDeadline
  , targetWorkerIntentImageDigest
  , targetWorkerIntentJobName
  , targetWorkerIntentRequestDigest
  , targetWorkerIntentSchema
  , targetWorkerIntentServiceAccount
  , targetWorkerIntentSignedBytes
  , targetWorkerIntentTarget
  , targetWorkerJobUidText
  , targetWorkerPodUidText
  , targetWorkerSchemaToken
  , targetWorkerServiceAccountUidText
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( SignedTargetWorkerExecutionPermit
  , decodeTargetWorkerExecutionPermit
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , targetValueDigestText
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data TargetIntentAuthorityClient m = TargetIntentAuthorityClient
  { callTargetIntentAuthority
      :: TargetIntentIssueWireRequest
      -> m
           ( Either
               TargetIntentAuthorityClientError
               (SignedTargetCommittedIntent, AcceptedTargetAuthority)
           )
  , callTargetExecutionPermitAuthority
      :: TargetExecutionPermitWireRequest
      -> m
           ( Either
               TargetIntentAuthorityClientError
               SignedTargetWorkerExecutionPermit
           )
  }

data TargetIntentAuthorityClientError
  = TargetIntentAuthorityTransportFailed !AuthenticatedClientError
  | TargetIntentAuthorityResponseInvalid !ControlPlaneResponseCodecError
  | TargetIntentAuthorityAuthenticatedResponseInvalid
      !AuthenticatedRolePlainResponseObservation
      !ControlPlaneResponseCodecError
  | TargetIntentAuthorityHttpStatus !Int
  | TargetIntentAuthorityRefused !Text
  | TargetIntentAuthorityUnavailable !Text
  | TargetIntentAuthoritySignedIntentInvalid
  | TargetIntentAuthorityTrustRecordInvalid
  | TargetIntentAuthorityExecutionPermitInvalid
  deriving stock (Eq, Show)

targetIntentAuthorityClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> TargetIntentAuthorityClient IO
targetIntentAuthorityClient transport =
  TargetIntentAuthorityClient
    call
    callPermit
 where
  call request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleTargetIntentIssueRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first TargetIntentAuthorityTransportFailed attempted
      response <-
        first
          (classifyTargetIntentAuthorityResponseDecodeFailure status body)
          ( decodeControlPlaneResponse
              targetIntentIssueResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      case response of
        TargetIntentIssueAuthorized signedBytes acceptedBytes
          | status == 200 -> do
              signed <-
                first
                  (const TargetIntentAuthoritySignedIntentInvalid)
                  ( decodeSignedTargetCommittedIntent
                      targetCommittedIntentMaximumEncodedBytes
                      signedBytes
                  )
              accepted <-
                first
                  (const TargetIntentAuthorityTrustRecordInvalid)
                  ( decodeAcceptedTargetAuthority
                      acceptedTargetAuthorityMaximumEncodedBytes
                      acceptedBytes
                  )
              Right (signed, accepted)
          | otherwise -> Left (TargetIntentAuthorityHttpStatus status)
        TargetExecutionPermitAuthorized _ ->
          Left (TargetIntentAuthorityHttpStatus status)
        TargetIntentIssueRefused detail ->
          Left (TargetIntentAuthorityRefused detail)
        TargetIntentIssueUnavailable detail ->
          Left (TargetIntentAuthorityUnavailable detail)

  callPermit request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleTargetIntentIssueRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first TargetIntentAuthorityTransportFailed attempted
      response <-
        first
          (classifyTargetIntentAuthorityResponseDecodeFailure status body)
          ( decodeControlPlaneResponse
              targetIntentIssueResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      case response of
        TargetExecutionPermitAuthorized permitBytes
          | status == 200 ->
              first
                (const TargetIntentAuthorityExecutionPermitInvalid)
                (decodeTargetWorkerExecutionPermit permitBytes)
          | otherwise -> Left (TargetIntentAuthorityHttpStatus status)
        TargetIntentIssueAuthorized {} ->
          Left (TargetIntentAuthorityHttpStatus status)
        TargetIntentIssueRefused detail ->
          Left (TargetIntentAuthorityRefused detail)
        TargetIntentIssueUnavailable detail ->
          Left (TargetIntentAuthorityUnavailable detail)

classifyTargetIntentAuthorityResponseDecodeFailure
  :: Int
  -> ByteString
  -> ControlPlaneResponseCodecError
  -> TargetIntentAuthorityClientError
classifyTargetIntentAuthorityResponseDecodeFailure status body codec =
  case classifyAuthenticatedRolePlainResponse status body of
    known@(AuthenticatedRolePlainResponseKnown _) ->
      TargetIntentAuthorityAuthenticatedResponseInvalid known codec
    AuthenticatedRolePlainResponseOther ->
      TargetIntentAuthorityResponseInvalid codec

requestTargetCommittedIntent
  :: (Monad m)
  => TargetIntentAuthorityClient m
  -> TargetSecretId
  -> TargetAgentIdentity
  -> CredentialGeneration
  -> TargetValueDigest
  -> Text
  -> Natural
  -> Text
  -> m
       ( Either
           TargetIntentAuthorityClientError
           (SignedTargetCommittedIntent, AcceptedTargetAuthority)
       )
requestTargetCommittedIntent client target agentIdentity generation receiptDigest operationId actionIndex idempotencyKey =
  callTargetIntentAuthority
    client
    TargetIntentIssueWireRequest
      { targetIntentIssueWireTarget = target
      , targetIntentIssueWireAgentIdentity = targetAgentIdentityText agentIdentity
      , targetIntentIssueWireGeneration = credentialGenerationValue generation
      , targetIntentIssueWireReceiptDigest = targetValueDigestText receiptDigest
      , targetIntentIssueWireOperationId = operationId
      , targetIntentIssueWireActionIndex = actionIndex
      , targetIntentIssueWireIdempotencyKey = idempotencyKey
      }

requestTargetWorkerExecutionPermit
  :: (Monad m)
  => TargetIntentAuthorityClient m
  -> TargetAgentRolloutEvidence
  -> TargetWorkerAttestation
  -> ServiceSessionBinding
  -> m
       ( Either
           TargetIntentAuthorityClientError
           SignedTargetWorkerExecutionPermit
       )
requestTargetWorkerExecutionPermit client rollout attestation sessionBinding =
  callTargetExecutionPermitAuthority
    client
    TargetExecutionPermitWireRequest
      { targetExecutionPermitWireSignedIntent = targetWorkerIntentSignedBytes intent
      , targetExecutionPermitWireSchema = targetWorkerIntentSchema intent
      , targetExecutionPermitWireImageDigest =
          targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
      , targetExecutionPermitWireAgentIdentity =
          targetAgentIdentityText (targetAgentRolloutEvidenceIdentity rollout)
      , targetExecutionPermitWireDeploymentUid =
          targetAgentRolloutDeploymentUid rollout
      , targetExecutionPermitWireDeploymentGeneration =
          targetAgentRolloutDeploymentGeneration rollout
      , targetExecutionPermitWireObservedDeploymentGeneration =
          targetAgentRolloutObservedGeneration rollout
      , targetExecutionPermitWireObservedRolloutDigest =
          targetAgentRolloutObservedDigest rollout
      , targetExecutionPermitWireObservation = observation
      , targetExecutionPermitWireSessionRole = serviceSessionBindingRole sessionBinding
      , targetExecutionPermitWireSessionOperationId =
          serviceSessionBindingOperationId sessionBinding
      , targetExecutionPermitWireSessionAttemptId =
          serviceSessionBindingAttemptId sessionBinding
      , targetExecutionPermitWireSessionFence = serviceSessionBindingFence sessionBinding
      }
 where
  intent = targetWorkerAttestedIntent attestation
  observation =
    RawTargetWorkerPodObservation
      { observedTargetWorkerJobName = targetWorkerIntentJobName intent
      , observedTargetWorkerJobUid =
          targetWorkerJobUidText (targetWorkerAttestedJobUid attestation)
      , observedTargetWorkerPodName = targetWorkerAttestedPodName attestation
      , observedTargetWorkerPodUid =
          targetWorkerPodUidText (targetWorkerAttestedPodUid attestation)
      , observedTargetWorkerImageDigest =
          targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
      , observedTargetWorkerServiceAccount = targetWorkerIntentServiceAccount intent
      , observedTargetWorkerServiceAccountUid =
          targetWorkerServiceAccountUidText
            (targetWorkerAttestedServiceAccountUid attestation)
      , observedTargetWorkerTarget = targetSecretIdToken (targetWorkerIntentTarget intent)
      , observedTargetWorkerAgentIdentity =
          targetAgentIdentityText (targetAgentRolloutEvidenceIdentity rollout)
      , observedTargetWorkerSchema = targetWorkerSchemaToken (targetWorkerIntentSchema intent)
      , observedTargetWorkerRequestDigest =
          targetValueDigestText (targetWorkerIntentRequestDigest intent)
      , observedTargetWorkerDeadlineMicros =
          authorityTimeMicros (targetWorkerIntentDeadline intent)
      , observedTargetWorkerPhase = "Running"
      , observedTargetWorkerReady = True
      , observedTargetWorkerRestartCount = 0
      , observedTargetWorkerDeletionTimestamp = Nothing
      }
