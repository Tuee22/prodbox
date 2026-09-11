{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetSecretWorker
  ( controlPlaneTargetSecretWorkerSuite
  )
where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (forM_)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Bits (xor)
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
import Prodbox.ControlPlane.ClosedSession (finishClosedSession)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , ServiceSessionJournal
  , ServiceSessionJournalRepository (..)
  , ServiceSessionJournalSnapshot (..)
  , ServiceSessionPhase (..)
  , mkInitialServiceSessionJournal
  , mkServiceSessionBinding
  , serviceSessionBindingFence
  , serviceSessionJournalPhase
  )
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLifecycleError (..)
  )
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustInstallError (..)
  , TargetAuthorityTrustInstallResult (..)
  , TargetAuthorityTrustObservation (..)
  , TargetAuthorityTrustObservationCause (..)
  , TargetAuthorityTrustRepository (..)
  , classifyTargetAuthorityTrustRecord
  , installTargetAuthorityTrust
  , targetAuthorityTrustDesiredMatchesLocal
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( targetMaterialMetadataVaultVersionField
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential, TargetPublicEdgeTls)
  , TargetSecretPayload (..)
  , compiledTargetSecretSink
  , targetSecretIdToken
  , targetSecretPayloadId
  , targetSecretPayloadToVaultFields
  )
import Prodbox.ControlPlane.TargetMaterializationProduction
  ( renderTargetWorkerCoordinatorDiagnostic
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.ControlPlane.TargetSecretWorker
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
import Prodbox.ControlPlane.TargetSecretWorkerKubernetes
import Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( classifyTargetAgentRolloutExit
  , classifyTargetWorkerServiceAccountObservation
  , classifyTargetWorkerSessionPrepareError
  , parseTargetAgentRolloutObservation
  , parseTargetWorkerServiceAccountObservation
  , recoverTargetWorkerCreateWith
  , runtimeImageIdentityMatches
  , targetWorkerActiveAccessorSubject
  , targetWorkerAttachTransportFailureDetail
  , targetWorkerOutcomeExitMatches
  , targetWorkerRetainedExecutionBoundary
  , targetWorkerRoleWideAccessorSubject
  , terminalTargetWorkerObservation
  )
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
import Prodbox.ControlPlane.TargetSecretWorkerRuntime
  ( TargetSecretWorkerRuntimeError (..)
  , TargetWorkerAuditorRecoveryBoundary (..)
  , acquireTargetWorkerAuditorWith
  , classifyTlsHomeRewrapWorkerResult
  , renderTargetSecretWorkerRuntimeRefusal
  , targetSecretWorkerTlsHomeRewrapRefusalTokens
  , targetWorkerServiceLoginAccepted
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( TargetWorkerExecutionPermitError (..)
  , VerifiedTargetWorkerExecutionPermit
  , decodeTargetWorkerExecutionPermit
  , encodeTargetWorkerExecutionPermit
  , issueTargetWorkerExecutionPermit
  , targetWorkerExecutionPermitMatchesObservation
  , targetWorkerSessionAttemptId
  , targetWorkerSessionOperationId
  , verifyTargetWorkerExecutionPermit
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekExchangeError (..)
  , TlsDekTransitBoundary (..)
  , TlsDekTransitFailure (..)
  , mkTlsWrappedDek
  , prepareTlsDekExchange
  , rewrapTlsDekFromRetainedHome
  , tlsDekPreparedPublicKey
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsHomeRewrapResult (..)
  , TlsSecretApplyFailure (..)
  , TlsTargetAgentError (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentProduction
  ( classifyTlsDekTransitOperationError
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditError (..)
  , VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  )
import Prodbox.Crypto.Aead (AeadError (AeadAuthenticationFailed))
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.CheckpointAuthority (TargetClusterSecretSink)
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , fencingTokenValue
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  , sha256TargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , FramedSubprocessExchangeError (..)
  , FramedSubprocessExchangeTransportStage (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessFramedExchangeBounded
  )
import Prodbox.Vault.Client
  ( TokenAccessorInfo (..)
  , VaultKubernetesLoginResult (..)
  , VaultToken (..)
  )
import Prodbox.Vault.Session
  ( VaultSessionError (..)
  , VaultSessionOperationError (..)
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import TestSupport

data AuditorFixtureLogin
  = AuditorFixtureInvalid
  | AuditorFixtureValid
  deriving stock (Eq, Show)

controlPlaneTargetSecretWorkerSuite :: SuiteBuilder ()
controlPlaneTargetSecretWorkerSuite =
  describe "Sprint 4.50 attested one-shot Target materializer" $ do
    it "binds the signed intent to exact target/schema/image/SA/request/Pod UID" $ do
      let intent = workerIntent
      targetWorkerIntentTarget intent `shouldBe` workerTarget
      targetWorkerIntentSchema intent `shouldBe` TargetWorkerDirectAws
      targetWorkerIntentJobName intent `shouldSatisfy` ("target-secret-" `prefixOf`)
      let attestation = workerAttestation intent
      targetWorkerAttestedPodUid attestation `shouldBe` workerPodUid
      case attestTargetWorkerPod
        admissionTime
        intent
        (rawWorkerObservation intent) {observedTargetWorkerImageDigest = otherImageDigestText} of
        Left TargetWorkerAttestationImageMismatch -> pure ()
        _ -> expectationFailure "expected immutable-image attestation refusal"

    it "renders every attestation refusal as one closed payload-free diagnostic" $ do
      map renderTargetWorkerAttestationError allTargetWorkerAttestationErrors
        `shouldBe` [ "deadline-reached"
                   , "job-mismatch"
                   , "job-uid-invalid"
                   , "pod-name-invalid"
                   , "pod-uid-invalid"
                   , "image-mismatch"
                   , "service-account-mismatch"
                   , "service-account-uid-invalid"
                   , "target-mismatch"
                   , "agent-identity-mismatch"
                   , "schema-mismatch"
                   , "request-mismatch"
                   , "deadline-mismatch"
                   , "not-running"
                   , "not-ready"
                   , "restarted"
                   , "deleting"
                   ]
      map
        ( renderTargetWorkerCoordinatorDiagnostic
            . TargetWorkerCoordinatorAttestationFailed
        )
        allTargetWorkerAttestationErrors
        `shouldBe` map
          (("attestation-failed/" <>) . renderTargetWorkerAttestationError)
          allTargetWorkerAttestationErrors

    it "refines only closed Target worker attach failures without retaining detail" $ do
      let diagnostic detail =
            renderTargetWorkerCoordinatorDiagnostic
              (TargetWorkerCoordinatorAttachFailed detail)
      map
        (diagnostic . targetWorkerAttachTransportFailureDetail)
        ([minBound .. maxBound] :: [FramedSubprocessExchangeTransportStage])
        `shouldBe` [ "attach-failed/limits-invalid"
                   , "attach-failed/initial-payload-invalid"
                   , "attach-failed/process-start-unavailable"
                   , "attach-failed/initial-payload-write-unavailable"
                   , "attach-failed/provisional-read-unavailable"
                   , "attach-failed/decision-continuation-write-unavailable"
                   , "attach-failed/completion-collection-unavailable"
                   , "attach-failed/wall-clock-timeout"
                   ]
      diagnostic "Target worker cleanup acknowledgement is invalid"
        `shouldBe` "attach-failed/cleanup-ack-invalid"
      diagnostic "Target worker terminal status is inconsistent"
        `shouldBe` "attach-failed/terminal-status-inconsistent"
      diagnostic "private-detail-a" `shouldBe` "attach-failed/other"
      diagnostic "private-detail-b" `shouldBe` "attach-failed/other"

    -- Sprint 6.5: a live TLS prepare refused at bare `session-cleanup-failed`,
    -- and nothing anywhere recorded which close step failed. Session close now
    -- classifies exactly as session prepare already does, and an unrecognized
    -- shape says so instead of echoing interpreter text.
    it "refines retained session cleanup to one closed value-free stage" $ do
      let diagnostic detail =
            renderTargetWorkerCoordinatorDiagnostic
              (TargetWorkerCoordinatorSessionCleanupFailed detail)
      diagnostic "cleanup-threw" `shouldBe` "session-cleanup-failed/cleanup-threw"
      map
        (diagnostic . Text.pack . show)
        [ ServiceSessionLifecycleBindingRoleMismatch
        , ServiceSessionLifecycleRoleOccupied
        , ServiceSessionLifecycleAccessorInvalid
        , ServiceSessionLifecycleAccessorIdentityMismatch
        , ServiceSessionLifecycleCleanupThrew
        , ServiceSessionLifecycleLoginAmbiguityCleaned
        , ServiceSessionLifecycleUnhandledException
        ]
        `shouldBe` [ "session-cleanup-failed/binding-role-mismatch"
                   , "session-cleanup-failed/role-occupied"
                   , "session-cleanup-failed/accessor-invalid"
                   , "session-cleanup-failed/accessor-identity-mismatch"
                   , "session-cleanup-failed/accessor-cleanup-threw"
                   , "session-cleanup-failed/login-ambiguity-cleaned"
                   , "session-cleanup-failed/unhandled-exception"
                   ]
      diagnostic (Text.pack (show (ServiceSessionLifecycleJournalUnavailable "private")))
        `shouldBe` "session-cleanup-failed/journal-unavailable"
      diagnostic (Text.pack (show (ServiceSessionLifecycleActionFailed "private")))
        `shouldBe` "session-cleanup-failed/action-failed"
      diagnostic "private-detail" `shouldBe` "session-cleanup-failed/unrecognized"

    it "refines retained session preparation to one closed value-free stage" $ do
      let causes = [minBound .. maxBound] :: [TargetWorkerSessionPrepareCause]
          diagnostic =
            renderTargetWorkerCoordinatorDiagnostic
              . TargetWorkerCoordinatorSessionPrepareFailed
      map diagnostic causes
        `shouldBe` [ "session-prepare-failed/journal-write-failed"
                   , "session-prepare-failed/journal-unavailable"
                   , "session-prepare-failed/binding-role-mismatch"
                   , "session-prepare-failed/role-occupied"
                   , "session-prepare-failed/binding-invalid"
                   , "session-prepare-failed/preclean/identity-invalid"
                   , "session-prepare-failed/preclean/auditor-login-failed"
                   , "session-prepare-failed/preclean/auditor-evidence-invalid"
                   , "session-prepare-failed/preclean/observation-failed"
                   , "session-prepare-failed/preclean/classification-failed"
                   , "session-prepare-failed/preclean/known-identity-mismatch"
                   , "session-prepare-failed/preclean/revocation-failed"
                   , "session-prepare-failed/preclean/visibility-wait-failed"
                   , "session-prepare-failed/preclean/stable-absence-failed"
                   , "session-prepare-failed/login-failed-cleaned"
                   , "session-prepare-failed/login-ambiguity-cleaned"
                   , "session-prepare-failed/accessor-invalid"
                   , "session-prepare-failed/accessor-identity-mismatch"
                   , "session-prepare-failed/cleanup-failed"
                   , "session-prepare-failed/cleanup-threw"
                   , "session-prepare-failed/cleanup-journal-failed"
                   , "session-prepare-failed/action-failed"
                   , "session-prepare-failed/unhandled-exception"
                   ]
      classifyTargetWorkerSessionPrepareError
        (ServiceSessionLifecycleJournalUnavailable "private-detail-a")
        `shouldBe` TargetWorkerSessionPrepareJournalUnavailable
      classifyTargetWorkerSessionPrepareError
        (ServiceSessionLifecycleJournalUnavailable "private-detail-b")
        `shouldBe` TargetWorkerSessionPrepareJournalUnavailable
      classifyTargetWorkerSessionPrepareError
        (ServiceSessionLifecycleActionFailed "private-detail")
        `shouldBe` TargetWorkerSessionPrepareActionFailed
      map
        ( classifyTargetWorkerSessionPrepareError
            . ServiceSessionLifecyclePrecleanFailed
        )
        [ VaultAccessorAuditIdentityInvalid
        , VaultAccessorAuditorLoginFailed
        , VaultAccessorAuditorEvidenceInvalid
        , VaultAccessorObservationFailed
        , VaultAccessorClassificationFailed
        , VaultAccessorKnownIdentityMismatch
        , VaultAccessorRevocationFailed
        , VaultAccessorVisibilityWaitFailed
        , VaultAccessorStableAbsenceFailed
        ]
        `shouldBe` [ TargetWorkerSessionPreparePrecleanIdentityInvalid
                   , TargetWorkerSessionPreparePrecleanAuditorLoginFailed
                   , TargetWorkerSessionPreparePrecleanAuditorEvidenceInvalid
                   , TargetWorkerSessionPreparePrecleanObservationFailed
                   , TargetWorkerSessionPreparePrecleanClassificationFailed
                   , TargetWorkerSessionPreparePrecleanKnownIdentityMismatch
                   , TargetWorkerSessionPreparePrecleanRevocationFailed
                   , TargetWorkerSessionPreparePrecleanVisibilityWaitFailed
                   , TargetWorkerSessionPreparePrecleanStableAbsenceFailed
                   ]

    it "classifies a worker exit before its provisional frame at the closed read stage" $ do
      result <-
        captureSubprocessFramedExchangeBounded
          (BoundedSubprocessLimits 64 64 64 1000000)
          "frame"
          (\_ -> pure (Right (ByteString.empty, ())))
          (Subprocess "/bin/sh" ["-c", "head -c 9 >/dev/null"] Nothing Nothing)
          :: IO
               ( Either
                   (FramedSubprocessExchangeError ())
                   ((), ProcessOutput)
               )
      case result of
        Left (FramedSubprocessExchangeTransportError FramedExchangeProvisionalRead _) ->
          pure ()
        _ -> expectationFailure "expected closed provisional-read transport stage"

    it "refines only closed value-free TLS worker refusals" $ do
      let runtimeToken = renderTargetSecretWorkerRuntimeRefusal
          diagnostic detail =
            renderTargetWorkerCoordinatorDiagnostic
              (TargetWorkerCoordinatorMaterializationRefused detail)
          restoreCases =
            [ (TlsTargetSecretUnavailable, "secret-unavailable")
            , (TlsTargetSecretInvalid, "secret-invalid")
            , (TlsTargetSecretReadBackMismatch, "secret-readback-mismatch")
            ,
              ( TlsTargetDekExchangeFailed
                  (TlsDekPrivateTokenUnavailable TlsDekTransitRequestBadRequestOther)
              , "dek-exchange-failed"
              )
            ,
              ( TlsTargetCipherFailed AeadAuthenticationFailed
              , "cipher-failed"
              )
            ,
              ( TlsTargetCertificateCiphertextInvalid
              , "certificate-ciphertext-invalid"
              )
            ,
              ( TlsTargetCertificateCiphertextTooLarge 1 2
              , "certificate-ciphertext-too-large"
              )
            , (TlsTargetReferenceMismatch, "reference-mismatch")
            ]
          homeRewrapCases =
            [ (TlsDekLengthInvalid 123, "length-invalid")
            , (TlsDekPublicKeyInvalid, "public-key-invalid")
            , (TlsDekSecretKeyInvalid, "secret-key-invalid")
            , (TlsDekPrivateTokenInvalid, "private-token-invalid")
            ,
              ( TlsDekPrivateTokenUnavailable TlsDekTransitRequestBadRequestOther
              , "private-token-unavailable"
              )
            , (TlsDekEnvelopeBindingMismatch, "envelope-binding-mismatch")
            , (TlsDekEnvelopeVersionUnsupported 123, "envelope-version-unsupported")
            , (TlsDekCipherFailed AeadAuthenticationFailed, "cipher-failed")
            ,
              ( TlsDekTransitWrapUnavailable TlsDekTransitRequestBadRequestOther
              , "transit-wrap-unavailable"
              )
            , (TlsDekWrappedCiphertextInvalid, "wrapped-ciphertext-invalid")
            ]
          transitFailureTokens =
            [ "session-acquisition-sealed"
            , "session-acquisition-forbidden"
            , "session-acquisition-unavailable"
            , "session-relogin-sealed"
            , "session-relogin-forbidden"
            , "session-relogin-unavailable"
            , "request-bad-request/missing-ciphertext"
            , "request-bad-request/key-not-found"
            , "request-bad-request/ciphertext-no-prefix"
            , "request-bad-request/ciphertext-wrong-fields"
            , "request-bad-request/ciphertext-version-undecodable"
            , "request-bad-request/ciphertext-version-too-new"
            , "request-bad-request/ciphertext-version-too-old"
            , "request-bad-request/convergent-nonce-invalid"
            , "request-bad-request/ciphertext-base64-invalid"
            , "request-bad-request/ciphertext-length-invalid"
            , "request-bad-request/ciphertext-authentication-failed"
            , "request-bad-request/other"
            , "request-unauthorized"
            , "request-forbidden"
            , "request-not-found"
            , "request-throttled"
            , "request-client-failure"
            , "request-server-failure"
            , "request-unexpected-status"
            , "request-connection-failure"
            , "request-timeout"
            , "request-decode-failure"
            , "unexpected-exception"
            ]
          transitFailures = [minBound .. maxBound] :: [TlsDekTransitFailure]
          transitFailureCases = zip transitFailures transitFailureTokens
          operationFailureCases =
            [
              ( VaultSessionAcquisitionFailed (VaultSessionSealed "detail-a")
              , TlsDekTransitSessionAcquisitionSealed
              )
            ,
              ( VaultSessionAcquisitionFailed (VaultSessionForbidden "detail-a")
              , TlsDekTransitSessionAcquisitionForbidden
              )
            ,
              ( VaultSessionAcquisitionFailed (VaultSessionUnavailable "detail-a")
              , TlsDekTransitSessionAcquisitionUnavailable
              )
            ,
              ( VaultSessionReloginFailed (VaultSessionSealed "detail-a")
              , TlsDekTransitSessionReloginSealed
              )
            ,
              ( VaultSessionReloginFailed (VaultSessionForbidden "detail-a")
              , TlsDekTransitSessionReloginForbidden
              )
            ,
              ( VaultSessionReloginFailed (VaultSessionUnavailable "detail-a")
              , TlsDekTransitSessionReloginUnavailable
              )
            ,
              ( VaultSessionRequestFailed
                  (HttpStatus 400 "{\"errors\":[\"cipher: message authentication failed\"]}")
              , TlsDekTransitRequestBadRequestCiphertextAuthenticationFailed
              )
            , (VaultSessionRequestFailed (HttpStatus 401 "detail-a"), TlsDekTransitRequestUnauthorized)
            , (VaultSessionRequestFailed (HttpStatus 403 "detail-a"), TlsDekTransitRequestForbidden)
            , (VaultSessionRequestFailed (HttpStatus 404 "detail-a"), TlsDekTransitRequestNotFound)
            , (VaultSessionRequestFailed (HttpStatus 429 "detail-a"), TlsDekTransitRequestThrottled)
            , (VaultSessionRequestFailed (HttpStatus 422 "detail-a"), TlsDekTransitRequestClientFailure)
            , (VaultSessionRequestFailed (HttpStatus 503 "detail-a"), TlsDekTransitRequestServerFailure)
            ,
              ( VaultSessionRequestFailed (HttpStatus 302 "detail-a")
              , TlsDekTransitRequestUnexpectedStatus
              )
            ,
              ( VaultSessionRequestFailed (HttpConnectionFailure "detail-a")
              , TlsDekTransitRequestConnectionFailure
              )
            , (VaultSessionRequestFailed (HttpTimeout "detail-a"), TlsDekTransitRequestTimeout)
            , (VaultSessionRequestFailed (HttpDecode "detail-a"), TlsDekTransitRequestDecodeFailure)
            ]
          applyFailureTokens =
            [ "initial-observation-unavailable"
            , "restore-slot-missing"
            , "existing-corrupt"
            , "existing-content-mismatch"
            , "request-invalid"
            , "transport-unavailable"
            , "http-bad-request"
            , "http-unauthorized"
            , "http-forbidden"
            , "http-not-found"
            , "http-method-not-allowed"
            , "http-conflict"
            , "http-unsupported-media-type"
            , "http-unprocessable"
            , "http-throttled"
            , "http-server-unavailable"
            , "http-unexpected-status"
            , "read-back-unavailable"
            , "read-back-missing"
            , "read-back-restore-slot"
            , "read-back-corrupt"
            , "read-back-content-mismatch"
            ]
          applyFailures = [minBound .. maxBound] :: [TlsSecretApplyFailure]
          applyCases = zip applyFailures applyFailureTokens
      runtimeToken TargetSecretWorkerTlsRetainProductionBoundaryUnavailable
        `shouldBe` "tls-retain/production-boundary-unavailable"
      runtimeToken (TargetSecretWorkerTlsRetainFailed TlsTargetSecretUnavailable)
        `shouldBe` "tls-retain/secret-unavailable"
      runtimeToken (TargetSecretWorkerTlsRetainFailed TlsTargetSecretInvalid)
        `shouldBe` "tls-retain/secret-invalid"
      runtimeToken
        (TargetSecretWorkerTlsRetainFailed (TlsTargetCertificateCiphertextTooLarge 1 2))
        `shouldBe` "tls-retain/certificate-ciphertext-too-large"
      runtimeToken TargetSecretWorkerTlsRetainBadRequest
        `shouldBe` "tls-retain/bad-request"
      diagnostic "tls-retain/secret-unavailable"
        `shouldBe` "materialization-refused/tls-retain/secret-unavailable"
      forM_ homeRewrapCases $ \(exchangeError, expected) -> do
        let refusal = "tls-home-rewrap/dek-exchange-failed/" <> expected
        runtimeToken
          (TargetSecretWorkerTlsHomeRewrapFailed (TlsTargetDekExchangeFailed exchangeError))
          `shouldBe` refusal
        diagnostic refusal `shouldBe` ("materialization-refused/" <> refusal)
      length transitFailures `shouldBe` length transitFailureTokens
      forM_ transitFailureCases $ \(failure, expected) -> do
        let refusal =
              "tls-home-rewrap/dek-exchange-failed/transit-unwrap-unavailable/"
                <> expected
        runtimeToken
          ( TargetSecretWorkerTlsHomeRewrapFailed
              (TlsTargetDekExchangeFailed (TlsDekTransitUnwrapUnavailable failure))
          )
          `shouldBe` refusal
        diagnostic refusal `shouldBe` ("materialization-refused/" <> refusal)
      classifyTlsHomeRewrapWorkerResult
        ( TlsHomeRewrapFailed
            ( TlsTargetDekExchangeFailed
                ( TlsDekTransitUnwrapUnavailable
                    TlsDekTransitRequestBadRequestCiphertextAuthenticationFailed
                )
            )
        )
        `shouldBe` Right TargetWorkerTlsHomeRewrapCiphertextAuthenticationFailedResult
      classifyTlsHomeRewrapWorkerResult
        ( TlsHomeRewrapFailed
            ( TlsTargetDekExchangeFailed
                (TlsDekTransitUnwrapUnavailable TlsDekTransitRequestBadRequestOther)
            )
        )
        `shouldBe` Left
          ( TargetSecretWorkerTlsHomeRewrapFailed
              ( TlsTargetDekExchangeFailed
                  (TlsDekTransitUnwrapUnavailable TlsDekTransitRequestBadRequestOther)
              )
          )
      forM_ operationFailureCases $ \(operationFailure, expected) ->
        classifyTlsDekTransitOperationError operationFailure `shouldBe` expected
      classifyTlsDekTransitOperationError
        (VaultSessionRequestFailed (HttpStatus 400 "detail-b"))
        `shouldBe` TlsDekTransitRequestBadRequestOther
      let badRequestCases =
            [
              ( "{\"errors\":[\"missing ciphertext to decrypt\"]}"
              , TlsDekTransitRequestBadRequestMissingCiphertext
              )
            ,
              ( "{\"errors\":[\"encryption key not found\"]}"
              , TlsDekTransitRequestBadRequestKeyNotFound
              )
            ,
              ( "{\"errors\":[\"invalid ciphertext: no prefix\"]}"
              , TlsDekTransitRequestBadRequestCiphertextNoPrefix
              )
            ,
              ( "{\"errors\":[\"invalid ciphertext: wrong number of fields\"]}"
              , TlsDekTransitRequestBadRequestCiphertextWrongFields
              )
            ,
              ( "{\"errors\":[\"invalid ciphertext: version number could not be decoded\"]}"
              , TlsDekTransitRequestBadRequestCiphertextVersionUndecodable
              )
            ,
              ( "{\"errors\":[\"invalid ciphertext: version is too new\"]}"
              , TlsDekTransitRequestBadRequestCiphertextVersionTooNew
              )
            ,
              ( "{\"errors\":[\"ciphertext or signature version is disallowed by policy (too old)\"]}"
              , TlsDekTransitRequestBadRequestCiphertextVersionTooOld
              )
            ,
              ( "{\"errors\":[\"invalid convergent nonce supplied\"]}"
              , TlsDekTransitRequestBadRequestConvergentNonceInvalid
              )
            ,
              ( "{\"errors\":[\"invalid ciphertext: could not decode base64\"]}"
              , TlsDekTransitRequestBadRequestCiphertextBase64Invalid
              )
            ,
              ( "{\"errors\":[\"invalid ciphertext length\"]}"
              , TlsDekTransitRequestBadRequestCiphertextLengthInvalid
              )
            ,
              ( "{\"errors\":[\"cipher: message authentication failed\"]}"
              , TlsDekTransitRequestBadRequestCiphertextAuthenticationFailed
              )
            ]
      forM_ badRequestCases $ \(body, expected) ->
        classifyTlsDekTransitOperationError
          (VaultSessionRequestFailed (HttpStatus 400 body))
          `shouldBe` expected
      classifyTlsDekTransitOperationError
        (VaultSessionRequestFailed (HttpStatus 400 "{\"errors\":[\"secret-detail\"]}"))
        `shouldBe` TlsDekTransitRequestBadRequestOther
      prepared <-
        mustRight
          <$> prepareTlsDekExchange
            TlsDekTransitBoundary
              { tlsDekTransitEncrypt = const (pure (Right "vault:v1:private-token"))
              , tlsDekTransitDecrypt = const (pure (Left TlsDekTransitRequestBadRequestOther))
              }
      rewrapTlsDekFromRetainedHome
        TlsDekTransitBoundary
          { tlsDekTransitEncrypt = const (pure (Right "vault:v1:unused"))
          , tlsDekTransitDecrypt = const (pure (Left TlsDekTransitRequestBadRequestOther))
          }
        (mustRight (mkTlsWrappedDek "vault:v1:retained-dek"))
        (tlsDekPreparedPublicKey prepared)
        `shouldReturn` Left (TlsDekTransitUnwrapUnavailable TlsDekTransitRequestBadRequestOther)
      runtimeToken (TargetSecretWorkerTlsHomeRewrapFailed TlsTargetSecretUnavailable)
        `shouldBe` "tls-home-rewrap/other-target-error"
      runtimeToken TargetSecretWorkerTlsHomeRewrapBadRequest
        `shouldBe` "tls-home-rewrap/bad-request"
      diagnostic "tls-home-rewrap/bad-request"
        `shouldBe` "materialization-refused/tls-home-rewrap/bad-request"
      length targetSecretWorkerTlsHomeRewrapRefusalTokens
        `shouldBe` (length homeRewrapCases + length transitFailureCases + 2)
      runtimeToken TargetSecretWorkerTlsRestoreProductionBoundaryUnavailable
        `shouldBe` "tls-restore/production-boundary-unavailable"
      runtimeToken TargetSecretWorkerTlsRestoreBadRequest
        `shouldBe` "tls-restore/bad-request"
      forM_ restoreCases $ \(targetError, expected) -> do
        let refusal = "tls-restore/" <> expected
        runtimeToken (TargetSecretWorkerTlsRestoreFailed targetError)
          `shouldBe` refusal
        diagnostic refusal `shouldBe` ("materialization-refused/" <> refusal)
      length applyFailures `shouldBe` length applyFailureTokens
      forM_ applyCases $ \(failure, expected) -> do
        let refusal = "tls-restore/secret-apply-failed/" <> expected
        runtimeToken
          (TargetSecretWorkerTlsRestoreFailed (TlsTargetSecretApplyFailed failure))
          `shouldBe` refusal
        diagnostic refusal `shouldBe` ("materialization-refused/" <> refusal)
      diagnostic "target-worker-materialization-refused"
        `shouldBe` "materialization-refused"
      diagnostic "private-detail-a" `shouldBe` "materialization-refused/other"
      diagnostic "private-detail-b" `shouldBe` "materialization-refused/other"

    it "treats kubectl attach exit as transport status for either provisional domain result" $ do
      let succeeded =
            TargetWorkerProvisionalSucceeded TargetWorkerTlsRetainMissingResult
          refused = TargetWorkerProvisionalRefused "closed-refusal"
      targetWorkerOutcomeExitMatches succeeded ExitSuccess `shouldBe` True
      targetWorkerOutcomeExitMatches refused ExitSuccess `shouldBe` True
      targetWorkerOutcomeExitMatches succeeded (ExitFailure 1) `shouldBe` False
      targetWorkerOutcomeExitMatches refused (ExitFailure 1) `shouldBe` False

    it "accepts canonical runtime identity forms and refuses a differing digest" $ do
      let expected = targetWorkerImageDigestText workerImageDigest
          repository = "127.0.0.1:30080/prodbox/prodbox-runtime"
      runtimeImageIdentityMatches expected ("containerd://" <> expected)
        `shouldBe` True
      runtimeImageIdentityMatches expected (repository <> "@" <> expected)
        `shouldBe` True
      runtimeImageIdentityMatches expected ("docker-pullable://" <> repository <> "@" <> expected)
        `shouldBe` True
      runtimeImageIdentityMatches expected ("containerd://" <> otherImageDigestText)
        `shouldBe` False
      runtimeImageIdentityMatches expected (repository <> "@" <> otherImageDigestText)
        `shouldBe` False
      runtimeImageIdentityMatches expected (repository <> "@@" <> expected)
        `shouldBe` False

    it "does not let final post-deadline absence erase a prior observation failure" $ do
      terminalTargetWorkerObservation
        (Just "Target worker image digest mismatch")
        (Right (Nothing :: Maybe Text))
        `shouldBe` Left "Target worker image digest mismatch"
      terminalTargetWorkerObservation
        Nothing
        (Right (Nothing :: Maybe Text))
        `shouldBe` Right Nothing
      terminalTargetWorkerObservation
        (Just "stale failure")
        (Right (Just ("observed" :: Text)))
        `shouldBe` Right (Just ("observed" :: Text))
      terminalTargetWorkerObservation
        (Just "stale failure")
        (Left "current failure" :: Either Text (Maybe Text))
        `shouldBe` Left "current failure"

    it "requires a fully observed exact Agent rollout on both Deployment surfaces" $ do
      parseTargetAgentRolloutObservation
        (agentDeploymentObservation workerAgentIdentity 1 1 (targetAgentRolloutDigest workerAgentIdentity))
        `shouldBe` Right workerAgentRollout
      parseTargetAgentRolloutObservation
        (agentDeploymentObservation workerAgentIdentity 2 1 (targetAgentRolloutDigest workerAgentIdentity))
        `shouldSatisfy` isLeftValue
      parseTargetAgentRolloutObservation
        (agentDeploymentObservationWithTemplateDigest workerAgentIdentity 1 1 otherImageDigestText)
        `shouldBe` Left TargetAgentRolloutDigestInconsistent
      parseTargetAgentRolloutObservation (agentDeploymentObservationWithoutAnnotations 1 1)
        `shouldBe` Left TargetAgentRolloutDeploymentIdentityAbsent
      classifyTargetAgentRolloutExit
        ( ProcessOutput
            (ExitFailure 1)
            ""
            "The connection to the server localhost:8080 was refused"
        )
        `shouldBe` TargetAgentRolloutKubeconfigUnavailable
      classifyTargetAgentRolloutExit
        (ProcessOutput (ExitFailure 1) "" "Error from server (Forbidden)")
        `shouldBe` TargetAgentRolloutAuthorizationRefused
      let substitutedIdentity =
            mustRight
              (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
      parseTargetAgentRolloutObservation
        ( agentDeploymentObservation
            substitutedIdentity
            1
            1
            (targetAgentRolloutDigest substitutedIdentity)
        )
        `shouldSatisfy` either
          (const False)
          ((/= workerAgentIdentity) . targetAgentRolloutEvidenceIdentity)

    it "Sprint 2.116 CAS-adopts only a same-cluster prior Agent rollout" $ do
      let target = acceptedTargetId acceptedAuthority
          prior = authorityForAgentAt priorWorkerAgentIdentity (AuthorityEpoch 3)
          foreignRecord = authorityForAgentAt foreignWorkerAgentIdentity (AuthorityEpoch 3)
      classifyTargetAuthorityTrustRecord workerAgentIdentity target 7 prior
        `shouldBe` TargetAuthorityTrustObserved 7 prior
      classifyTargetAuthorityTrustRecord workerAgentIdentity target 7 foreignRecord
        `shouldBe` TargetAuthorityTrustUnobservable
          TargetAuthorityTrustObservationAgentIdentityMismatch
      targetAuthorityTrustDesiredMatchesLocal workerAgentIdentity target acceptedAuthority
        `shouldBe` True
      targetAuthorityTrustDesiredMatchesLocal workerAgentIdentity target prior
        `shouldBe` False
      targetAuthorityTrustDesiredMatchesLocal workerAgentIdentity target tlsAcceptedAuthority
        `shouldBe` False

      state <- newIORef (7, prior)
      casAttempts <- newIORef (0 :: Natural)
      let repository =
            TargetAuthorityTrustRepository
              { observeTargetAuthorityTrust = \_ -> do
                  (version, observed) <- readIORef state
                  pure (TargetAuthorityTrustObserved version observed)
              , compareAndSwapTargetAuthorityTrust = \_ expected desired -> do
                  modifyIORef' casAttempts (+ 1)
                  (version, _) <- readIORef state
                  if expected == version
                    then writeIORef state (version + 1, desired) >> pure (Right ())
                    else pure (Left "CAS version mismatch")
              }
      installTargetAuthorityTrust repository acceptedAuthority
        `shouldReturn` Right (TargetAuthorityTrustInstalled acceptedAuthority)
      readIORef casAttempts `shouldReturn` 1
      readIORef state `shouldReturn` (8, acceptedAuthority)

      regressionCasAttempts <- newIORef (0 :: Natural)
      let refusingRepository observed =
            TargetAuthorityTrustRepository
              { observeTargetAuthorityTrust = \_ ->
                  pure (TargetAuthorityTrustObserved 7 observed)
              , compareAndSwapTargetAuthorityTrust = \_ _ _ -> do
                  modifyIORef' regressionCasAttempts (+ 1)
                  pure (Right ())
              }
      installTargetAuthorityTrust
        (refusingRepository prior)
        (authorityForAgentAt workerAgentIdentity (AuthorityEpoch 2))
        `shouldReturn` Left TargetAuthorityTrustEpochRegressed
      installTargetAuthorityTrust (refusingRepository foreignRecord) acceptedAuthority
        `shouldReturn` Left TargetAuthorityTrustAgentIdentityChanged
      readIORef regressionCasAttempts `shouldReturn` 0

    it "admits only an exact named ServiceAccount GET with an API-assigned UID" $ do
      let expectedUid =
            mustRight
              ( mkTargetWorkerServiceAccountUid
                  "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
              )
          valid =
            serviceAccountObservation
              (targetWorkerIntentServiceAccount workerIntent)
              "target-secret-agent"
              "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      parseTargetWorkerServiceAccountObservation workerIntent valid
        `shouldBe` Right expectedUid
      forM_
        [ serviceAccountObservation
            "foreign-service-account"
            "target-secret-agent"
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        , serviceAccountObservation
            (targetWorkerIntentServiceAccount workerIntent)
            "foreign-namespace"
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        , serviceAccountObservation
            (targetWorkerIntentServiceAccount workerIntent)
            "target-secret-agent"
            "invalid uid"
        , LazyByteString.toStrict
            ( Aeson.encode
                ( Aeson.object
                    [ "items"
                        Aeson..= [ Aeson.object []
                                 , Aeson.object []
                                 ]
                    ]
                )
            )
        , LazyByteString.toStrict
            ( Aeson.encode
                ( Aeson.object
                    [ "metadata"
                        Aeson..= Aeson.object
                          [ "name"
                              Aeson..= targetWorkerIntentServiceAccount workerIntent
                          , "namespace" Aeson..= ("target-secret-agent" :: Text)
                          ]
                    ]
                )
            )
        ]
        $ \substituted ->
          parseTargetWorkerServiceAccountObservation workerIntent substituted
            `shouldSatisfy` isLeftValue
      classifyTargetWorkerServiceAccountObservation
        workerIntent
        (Left "ServiceAccount GET transport unavailable")
        `shouldSatisfy` isLeftValue
      classifyTargetWorkerServiceAccountObservation
        workerIntent
        (Right (ProcessOutput (ExitFailure 1) "" "NotFound"))
        `shouldSatisfy` isLeftValue

    it "rejects static ServiceAccount and immutable-image substitution before permit issuance" $ do
      let intent = workerIntent
          cases =
            [
              ( (rawWorkerObservation intent)
                  { observedTargetWorkerServiceAccount = "substituted-worker"
                  }
              , TargetWorkerAttestationServiceAccountMismatch
              )
            ,
              ( (rawWorkerObservation intent)
                  { observedTargetWorkerImageDigest = otherImageDigestText
                  }
              , TargetWorkerAttestationImageMismatch
              )
            ]
          assertRefused (observation, expected) =
            case attestTargetWorkerPod admissionTime intent observation of
              Left actual -> actual `shouldBe` expected
              Right _ -> expectationFailure "expected Target worker attestation refusal"
      forM_ cases assertRefused

    it "binds signed permits to exact rollout, Job, Pod, SA UID, image, and an independent fence" $ do
      let originalAttestation = workerAttestation workerIntent
          originalBinding = workerSessionBinding originalAttestation
          substitutedObservations =
            [ (rawWorkerObservation workerIntent)
                { observedTargetWorkerJobUid = "job-uid-substituted"
                }
            , (rawWorkerObservation workerIntent)
                { observedTargetWorkerPodName = "target-secret-worker-pod-substituted"
                }
            , (rawWorkerObservation workerIntent)
                { observedTargetWorkerPodUid = "pod-uid-substituted"
                }
            , (rawWorkerObservation workerIntent)
                { observedTargetWorkerServiceAccountUid = "service-account-uid-substituted"
                }
            ]
      serviceSessionBindingFence originalBinding
        `shouldNotBe` fencingTokenValue (targetWorkerIntentFencingToken workerIntent)
      forM_ substitutedObservations $ \observation -> do
        let substitutedAttestation =
              mustAttestation
                (attestTargetWorkerPod admissionTime workerIntent observation)
            substitutedBinding = workerSessionBinding substitutedAttestation
        targetWorkerSessionAttemptId workerAgentRollout substitutedAttestation
          `shouldNotBe` targetWorkerSessionAttemptId workerAgentRollout originalAttestation
        signed <-
          issueTargetWorkerExecutionPermit
            permitSigner
            acceptedAuthority
            workerAgentRollout
            substitutedAttestation
            substitutedBinding
        let verified =
              mustRight
                ( verifyTargetWorkerExecutionPermit
                    acceptedAuthority
                    admissionTime
                    workerIntent
                    (mustRight signed)
                )
        targetWorkerExecutionPermitMatchesObservation
          workerAgentRollout
          originalAttestation
          originalBinding
          verified
          `shouldBe` False
      let wrongIdentity =
            mustRight
              (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
          wrongRollout =
            mustRight
              ( mkTargetAgentRolloutEvidence
                  wrongIdentity
                  "deployment-uid-substituted"
                  1
                  1
                  (targetAgentRolloutDigest wrongIdentity)
              )
          wrongBinding =
            mustRight
              ( mkServiceSessionBinding
                  targetSecretWorkerVaultRole
                  (targetWorkerSessionOperationId workerIntent)
                  (targetWorkerSessionAttemptId wrongRollout originalAttestation)
                  1
              )
      issueTargetWorkerExecutionPermit
        permitSigner
        acceptedAuthority
        wrongRollout
        originalAttestation
        wrongBinding
        `shouldReturn` Left TargetWorkerExecutionPermitTrustMismatch

    it "rejects a canonical execution-permit frame after signature mutation" $ do
      let attestation = workerAttestation workerIntent
      signed <-
        issueTargetWorkerExecutionPermit
          permitSigner
          acceptedAuthority
          workerAgentRollout
          attestation
          (workerSessionBinding attestation)
      let encoded = encodeTargetWorkerExecutionPermit (mustRight signed)
          mutated =
            ByteString.init encoded
              <> ByteString.singleton (ByteString.last encoded `xor` 1)
      case decodeTargetWorkerExecutionPermit mutated of
        Left err -> expectationFailure ("mutated permit did not remain canonical: " <> show err)
        Right decoded ->
          case verifyTargetWorkerExecutionPermit
            acceptedAuthority
            admissionTime
            workerIntent
            decoded of
            Left TargetWorkerExecutionPermitSignatureInvalid -> pure ()
            other -> expectationFailure ("expected signature refusal, got " <> showPermitResult other)

    it "round-trips only a bounded direct-stdin frame and rejects schema substitution" $ do
      let attestation = workerAttestation workerIntent
      permit <- workerExecutionPermit attestation
      let encoded =
            mustRight
              (encodeDirectTargetWorkerIngress permit attestation workerPayload)
      ByteString.isInfixOf "target-secret-value" encoded `shouldBe` True
      withTargetWorkerIngress
        encoded
        ( \binding payload ->
            ( targetWorkerFramePodUid binding
            , targetWorkerFrameTarget binding
            , targetWorkerFrameSchema binding
            , targetSecretPayloadId payload
            )
        )
        (\_ _ -> error "direct frame selected rewrapped callback")
        `shouldBe` Right
          (workerPodUid, workerTarget, TargetWorkerDirectAws, workerTarget)
      encodeRewrappedTargetWorkerIngress permit attestation "rewrapped"
        `shouldBe` Left TargetWorkerIngressSchemaMismatch

    it "selects one exact TLS arm and rejects a different arm before its continuation" $ do
      let attestation = tlsWorkerAttestation tlsWorkerIntent
      permit <- tlsWorkerExecutionPermit attestation
      let operation = TargetWorkerTlsPrepareInput
          encoded =
            mustRight
              (encodeTargetWorkerOperationIngress permit attestation operation)
      withTargetWorkerOperationIngress
        encoded
        (\binding selected -> (targetWorkerFrameSchema binding, selected))
        `shouldBe` Right (TargetWorkerTlsPrepare, operation)
      encodeTargetWorkerOperationIngress
        permit
        attestation
        (TargetWorkerDirectMaterialInput workerPayload)
        `shouldBe` Left TargetWorkerIngressSchemaMismatch
      targetWorkerOperationRequestDigest operation
        `shouldNotBe` targetWorkerOperationRequestDigest
          (TargetWorkerDirectMaterialInput workerPayload)

    it "requires the signed TLS operation commitment to match the exact stdin arm" $ do
      let attestation = tlsWorkerAttestation tlsWrongDigestIntent
      permit <- tlsWorkerExecutionPermit attestation
      encodeTargetWorkerOperationIngress
        permit
        attestation
        TargetWorkerTlsPrepareInput
        `shouldBe` Left TargetWorkerIngressIntentInvalid

    it "round-trips a typed TLS provisional result and rejects result-arm substitution" $ do
      prepared <-
        prepareTlsDekExchange
          TlsDekTransitBoundary
            { tlsDekTransitEncrypt = const (pure (Right "vault:v1:opaque-prepared"))
            , tlsDekTransitDecrypt = const (pure (Left TlsDekTransitUnexpectedException))
            }
      let result = TargetWorkerTlsPreparedResult (mustRight prepared)
          completion =
            mustRight
              ( successfulTargetWorkerOperationProvisionalCompletion
                  "worker-accessor"
                  result
              )
      decodeTargetWorkerProvisionalCompletion
        (encodeTargetWorkerProvisionalCompletion completion)
        `shouldBe` Right completion
      targetWorkerOperationResultMatchesSchema TargetWorkerTlsPrepare result
        `shouldBe` True
      targetWorkerOperationResultMatchesSchema TargetWorkerTlsVerify result
        `shouldBe` False

    it "performs one generation CAS, exact data/metadata readback, and idempotent replay" $ do
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      firstRun <- runMaterialization fixture
      firstRun `shouldSatisfy` isApplied
      readIORef (vaultCasWrites fixture) `shouldReturn` 1
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1
      secondRun <- runMaterialization fixture
      secondRun `shouldSatisfy` isAlreadyApplied
      readIORef (vaultCasWrites fixture) `shouldReturn` 1
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1

    it "repairs metadata after a crash between data CAS and custom-metadata publish" $ do
      let fields = mustRight (targetSecretPayloadToVaultFields workerPayload)
      fixture <-
        freshVaultFixture
          (TargetWorkerDataPresent 7 fields)
          TargetWorkerMetadataMissing
      result <- runMaterialization fixture
      result `shouldSatisfy` isRecovered
      readIORef (vaultCasWrites fixture) `shouldReturn` 0
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1

    it "keeps exact legacy metadata readable for rollout and repairs its Vault-version binding" $ do
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      initial <- runMaterialization fixture
      initial `shouldSatisfy` isApplied
      observed <- readIORef (vaultMetadata fixture)
      case observed of
        TargetWorkerMetadataMissing -> expectationFailure "expected published metadata"
        TargetWorkerMetadataPresent version custom ->
          writeIORef
            (vaultMetadata fixture)
            ( TargetWorkerMetadataPresent
                version
                (Map.delete targetMaterialMetadataVaultVersionField custom)
            )
      writeIORef (vaultMetadataWrites fixture) 0
      recovered <- runMaterialization fixture
      recovered `shouldSatisfy` isRecovered
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1
      repaired <- readIORef (vaultMetadata fixture)
      case repaired of
        TargetWorkerMetadataMissing -> expectationFailure "expected repaired metadata"
        TargetWorkerMetadataPresent version custom ->
          Map.lookup targetMaterialMetadataVaultVersionField custom
            `shouldBe` Just (Text.pack (show version))

    it "recovers a CAS response loss through authoritative readback without retry" $ do
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      writeIORef (vaultLoseCasResponse fixture) True
      result <- runMaterialization fixture
      result `shouldSatisfy` isRecovered
      readIORef (vaultCasWrites fixture) `shouldReturn` 1

    it "refuses same-generation commitment collision before any data write" $ do
      let fields = mustRight (targetSecretPayloadToVaultFields workerPayload)
          conflicting =
            Map.fromList
              [ ("prodbox_generation", "1")
              , ("prodbox_commitment", "vault:v1:different")
              ]
      fixture <-
        freshVaultFixture
          (TargetWorkerDataPresent 4 fields)
          (TargetWorkerMetadataPresent 4 conflicting)
      runMaterialization fixture
        `shouldReturn` Left (TargetWorkerExecutionGenerationCollision 1)
      readIORef (vaultCasWrites fixture) `shouldReturn` 0

    it "revokes the worker session and lets exact absence close a lost revoke response" $ do
      revocations <- newIORef (0 :: Int)
      let revoke = modifyIORef' revocations (+ 1) >> pure (Right ())
      finishTargetWorkerSession
        (pure (Left TargetWorkerExecutionDeadlineReached :: Either TargetWorkerExecutionError ()))
        revoke
        (pure (Right True))
        `shouldReturn` Left TargetWorkerExecutionDeadlineReached
      readIORef revocations `shouldReturn` 1
      finishTargetWorkerSession
        (pure (Right ()))
        (pure (Left TargetWorkerExecutionSessionRevocationFailed))
        (pure (Right True))
        `shouldReturn` Right ()

    it "runs revoke and exact-absence cleanup after thrown worker effects" $ do
      revocations <- newIORef (0 :: Int)
      observations <- newIORef (0 :: Int)
      finishClosedSession
        TargetWorkerExecutionDeadlineReached
        TargetWorkerExecutionSessionRevocationFailed
        (throwIO (userError "worker crashed"))
        (modifyIORef' revocations (+ 1) >> pure (Right ()))
        (modifyIORef' observations (+ 1) >> pure (Right True))
        `shouldReturn` (Left TargetWorkerExecutionDeadlineReached :: Either TargetWorkerExecutionError ())
      readIORef revocations `shouldReturn` 1
      readIORef observations `shouldReturn` 1

    it "accepts only an accessor-free bounded batch auditor" $ do
      let valid =
            VaultKubernetesLoginResult
              { vaultLoginToken = VaultToken "opaque-test-token"
              , vaultLoginAccessor = ""
              , vaultLoginLeaseSeconds = 120
              , vaultLoginRenewable = False
              , vaultLoginTokenType = "batch"
              }
      isBoundedBatchAuditorLogin 300 valid `shouldBe` True
      isBoundedBatchAuditorLogin 300 valid {vaultLoginTokenType = "service"}
        `shouldBe` False
      isBoundedBatchAuditorLogin 300 valid {vaultLoginAccessor = "unexpected-accessor"}
        `shouldBe` False

    it "accepts renewable accessor-bearing service evidence only within the hard cap" $ do
      let valid =
            VaultKubernetesLoginResult
              { vaultLoginToken = VaultToken "opaque-test-token"
              , vaultLoginAccessor = "accessor-1"
              , vaultLoginLeaseSeconds = 600
              , vaultLoginRenewable = True
              , vaultLoginTokenType = "service"
              }
      targetWorkerServiceLoginAccepted valid `shouldBe` True
      targetWorkerServiceLoginAccepted valid {vaultLoginLeaseSeconds = 0}
        `shouldBe` False
      targetWorkerServiceLoginAccepted valid {vaultLoginLeaseSeconds = 601}
        `shouldBe` False
      targetWorkerServiceLoginAccepted valid {vaultLoginAccessor = ""}
        `shouldBe` False
      targetWorkerServiceLoginAccepted valid {vaultLoginTokenType = "batch"}
        `shouldBe` False

    it "revokes and stably proves an invalid accessor-bearing auditor login absent before reuse" $ do
      logins <- newIORef [AuditorFixtureInvalid, AuditorFixtureValid]
      observations <- newIORef [False, True, True]
      events <- newIORef ([] :: [Text])
      let auditorAccessor login = case login of
            AuditorFixtureInvalid -> "drifted-auditor-accessor"
            AuditorFixtureValid -> ""
          boundary =
            TargetWorkerAuditorRecoveryBoundary
              { acquireTargetWorkerAuditorLogin = do
                  modifyIORef' events (++ ["login"])
                  remaining <- readIORef logins
                  case remaining of
                    [] -> pure (Left "fixture login exhausted")
                    login : rest -> writeIORef logins rest >> pure (Right login)
              , targetWorkerAuditorLoginAccepted = (== AuditorFixtureValid)
              , targetWorkerAuditorLoginMayHaveAccessor =
                  (== AuditorFixtureInvalid)
              , targetWorkerAuditorLoginAccessor = auditorAccessor
              , revokeTargetWorkerAuditorLogin = \_ ->
                  modifyIORef' events (++ ["revoke-login"]) >> pure (Left "response lost")
              , revokeTargetWorkerAuditorAccessor = \_ _ ->
                  modifyIORef' events (++ ["revoke-accessor"]) >> pure (Left "response lost")
              , observeTargetWorkerAuditorAccessorAbsent = \_ _ -> do
                  modifyIORef' events (++ ["observe-absence"])
                  remaining <- readIORef observations
                  case remaining of
                    [] -> pure (Left "fixture observation exhausted")
                    observed : rest ->
                      writeIORef observations rest >> pure (Right observed)
              , waitTargetWorkerAuditorVisibility =
                  modifyIORef' events (++ ["visibility-grace"])
              }
      acquireTargetWorkerAuditorWith 3 5 boundary
        `shouldReturn` Right AuditorFixtureValid
      readIORef events
        `shouldReturn` [ "login"
                       , "revoke-login"
                       , "login"
                       , "revoke-accessor"
                       , "observe-absence"
                       , "visibility-grace"
                       , "observe-absence"
                       , "visibility-grace"
                       , "observe-absence"
                       ]

    it "runs revoke and exact-absence cleanup after worker cancellation" $ do
      blocked <- newEmptyMVar :: IO (MVar ())
      started <- newEmptyMVar :: IO (MVar ())
      result <- newEmptyMVar
      revocations <- newIORef (0 :: Int)
      observations <- newIORef (0 :: Int)
      workerThread <-
        forkIO $ do
          outcome <-
            try
              ( finishClosedSession
                  TargetWorkerExecutionDeadlineReached
                  TargetWorkerExecutionSessionRevocationFailed
                  (putMVar started () >> takeMVar blocked >> pure (Right ()))
                  (modifyIORef' revocations (+ 1) >> pure (Right ()))
                  (modifyIORef' observations (+ 1) >> pure (Right True))
              )
          putMVar result outcome
      takeMVar started
      throwTo workerThread ThreadKilled
      takeMVar result
        `shouldReturn` (Left ThreadKilled :: Either AsyncException (Either TargetWorkerExecutionError ()))
      readIORef revocations `shouldReturn` 1
      readIORef observations `shouldReturn` 1

    it "always deletes and positively observes absence after an attach refusal" $ do
      deleted <- newIORef (0 :: Int)
      absent <- newIORef (0 :: Int)
      let boundary =
            TargetWorkerKubernetesBoundary
              { observeSelectedTargetAgentRollout = pure (Right workerAgentRollout)
              , createTargetWorkerIntent = const (pure (Right workerJobUid))
              , recoverTargetWorkerIntent =
                  const (pure (Right (TargetWorkerCreateRecovered workerJobUid)))
              , observeTargetWorkerIntent =
                  \intent -> pure (Right (Just (rawWorkerObservation intent)))
              , attachTargetWorkerIngress =
                  \_ _ _ ->
                    pure
                      (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
              , deleteTargetWorkerIntent = \_ _ _ ->
                  modifyIORef' deleted (+ 1) >> pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ ->
                  modifyIORef' absent (+ 1) >> pure (Right True)
              }
      result <-
        coordinateDirectTargetMaterialization
          boundary
          workerExecutionBoundary
          acceptedAuthority
          admissionTime
          workerAgentIdentity
          workerTarget
          TargetWorkerDirectAws
          workerImageDigest
          signedIntentBytes
          workerPayload
      result `shouldBe` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef deleted `shouldReturn` 1
      readIORef absent `shouldReturn` 1

    it "durably activates the exact server accessor before authorizing worker cleanup" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
      prepared <-
        prepareTargetWorkerSessionAttempt
          execution
          workerAgentRollout
          attestation
      binding <- case prepared of
        Left cause -> expectationFailure (show cause) >> pure (workerSessionBinding attestation)
        Right value -> pure value
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       ]
      activateTargetWorkerSessionAttempt
        execution
        attestation
        binding
        "worker-accessor"
        `shouldReturn` Right ()
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "audit:lookup"
                       , "journal:active"
                       ]
      closeTargetWorkerSessionAttempt execution binding `shouldReturn` Right ()
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "audit:lookup"
                       , "journal:active"
                       , "journal:cleanup-required"
                       , "audit:inventory"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "journal:cleanup-proven"
                       , "journal:vacant"
                       ]
      Map.member
        "service_account_uid"
        (vaultAccessorSubjectMetadata targetWorkerRoleWideAccessorSubject)
        `shouldBe` False
      Map.lookup
        "service_account_uid"
        ( vaultAccessorSubjectMetadata
            (targetWorkerActiveAccessorSubject attestation)
        )
        `shouldBe` Just (targetWorkerServiceAccountUidText workerServiceAccountUid)

    it "holds worker cleanup until the provisional accessor is Active, then closes the retained lane" $ do
      vaultFixture <-
        freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      materialized <- runMaterialization vaultFixture
      receipt <- case materialized of
        Right (TargetWorkerMaterializationApplied value) -> pure value
        Right (TargetWorkerMaterializationAlreadyApplied value) -> pure value
        Right (TargetWorkerMaterializationRecovered value) -> pure value
        Left err -> expectationFailure (show err) >> fail "materialization fixture failed"
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let retainedExecution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution =
            retainedExecution
              { authorizeTargetWorkerExecution =
                  authorizeTargetWorkerExecution workerExecutionBoundary
              }
          completion =
            mustRight
              (successfulTargetWorkerProvisionalCompletion "worker-accessor" receipt)
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ decide -> do
                  modifyIORef' events (++ ["worker:provisional"])
                  decided <- decide (encodeTargetWorkerProvisionalCompletion completion)
                  case decided of
                    Left err -> pure (Left err)
                    Right outcome -> do
                      modifyIORef'
                        events
                        (++ ["worker:cleanup-authorized", "worker:cleanup-complete"])
                      pure (Right outcome)
              }
      coordinateWithBoundary boundary execution `shouldReturn` Right receipt
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "worker:provisional"
                       , "audit:lookup"
                       , "journal:active"
                       , "worker:cleanup-authorized"
                       , "worker:cleanup-complete"
                       , "journal:cleanup-required"
                       , "audit:inventory"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "journal:cleanup-proven"
                       , "journal:vacant"
                       ]

    it "refuses an accessor classified to a substituted ServiceAccount UID before cleanup authorization" $ do
      vaultFixture <-
        freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      materialized <- runMaterialization vaultFixture
      receipt <- case materialized of
        Right (TargetWorkerMaterializationApplied value) -> pure value
        Right (TargetWorkerMaterializationAlreadyApplied value) -> pure value
        Right (TargetWorkerMaterializationRecovered value) -> pure value
        Left err -> expectationFailure (show err) >> fail "materialization fixture failed"
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let wrongUidAudit =
            (orderedTargetAuditOps events)
              { auditLookupAccessor = \_ ->
                  pure
                    ( Right
                        TokenAccessorInfo
                          { tokenAccessorInfoPolicies = ["default", targetSecretWorkerVaultRole]
                          , tokenAccessorInfoMetadata =
                              Map.insert
                                "service_account_uid"
                                "substituted-service-account-uid"
                                ( vaultAccessorSubjectMetadata
                                    ( targetWorkerActiveAccessorSubject
                                        (workerAttestation workerIntent)
                                    )
                                )
                          , tokenAccessorInfoCreationPath = "auth/kubernetes/login"
                          , tokenAccessorInfoDisplayName = "kubernetes-target-secret-worker"
                          }
                    )
              }
          retainedExecution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              wrongUidAudit
              unusedTargetIntentAuthorityClient
          execution =
            retainedExecution
              { authorizeTargetWorkerExecution =
                  authorizeTargetWorkerExecution workerExecutionBoundary
              }
          completion =
            mustRight
              (successfulTargetWorkerProvisionalCompletion "worker-accessor" receipt)
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ decide ->
                  decide (encodeTargetWorkerProvisionalCompletion completion)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left
          ( TargetWorkerCoordinatorSessionActivateFailed
              "ServiceSessionLifecycleAccessorIdentityMismatch"
          )
      fmap (filter (== "journal:active")) (readIORef events) `shouldReturn` []

    it "recovers an applied-but-response-lost Job create and still performs exact terminal cleanup" $ do
      recovered <- newIORef (0 :: Int)
      deleted <- newIORef ([] :: [Maybe (Text, TargetWorkerPodUid)])
      absent <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = const (pure (Left "create response lost"))
              , recoverTargetWorkerIntent = \_ -> do
                  modifyIORef' recovered (+ 1)
                  pure (Right (TargetWorkerCreateRecovered workerJobUid))
              , attachTargetWorkerIngress =
                  \_ _ _ ->
                    pure
                      (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
              , deleteTargetWorkerIntent = \_ _ maybePod -> do
                  modifyIORef' deleted (++ [maybePod])
                  pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ -> do
                  modifyIORef' absent (+ 1)
                  pure (Right True)
              }
      result <- coordinateWithBoundary boundary workerExecutionBoundary
      result `shouldBe` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef recovered `shouldReturn` 1
      readIORef deleted
        `shouldReturn` [Just ("target-secret-worker-pod", workerPodUid)]
      readIORef absent `shouldReturn` 1

    it "waits across the create visibility grace before recovering a delayed Job UID" $ do
      observations <-
        newIORef
          [ Right Nothing
          , Right (Just workerJobUid)
          ]
      graces <- newIORef (0 :: Int)
      retries <- newIORef (0 :: Int)
      recovered <-
        recoverTargetWorkerCreateWith
          4
          (modifyIORef' graces (+ 1))
          (modifyIORef' retries (+ 1))
          (nextCreateObservation observations)
      recovered `shouldBe` Right (TargetWorkerCreateRecovered workerJobUid)
      readIORef graces `shouldReturn` 1
      readIORef retries `shouldReturn` 0

    it "classifies create absence only after two observations across the visibility grace" $ do
      observations <-
        newIORef
          [ Right Nothing
          , Right Nothing
          ]
      graces <- newIORef (0 :: Int)
      recovered <-
        recoverTargetWorkerCreateWith
          4
          (modifyIORef' graces (+ 1))
          (pure ())
          (nextCreateObservation observations)
      recovered `shouldBe` Right TargetWorkerCreateStablyAbsent
      readIORef graces `shouldReturn` 1

    it "cleans the known Job when Pod observation fails or returns a foreign Job UID" $ do
      forM_
        [
          ( pure (Left "observation failed")
          , TargetWorkerCoordinatorObservationFailed "observation failed"
          )
        ,
          ( pure
              ( Right
                  ( Just
                      ( (rawWorkerObservation workerIntent)
                          { observedTargetWorkerJobUid = "foreign-job-uid"
                          }
                      )
                  )
              )
          , TargetWorkerCoordinatorCleanupBindingInvalid
          )
        ]
        $ \(observation, expected) -> do
          deleted <- newIORef ([] :: [Maybe (Text, TargetWorkerPodUid)])
          let boundary =
                standardWorkerBoundary
                  { observeTargetWorkerIntent = const observation
                  , deleteTargetWorkerIntent = \_ _ maybePod -> do
                      modifyIORef' deleted (++ [maybePod])
                      pure (Right ())
                  }
          coordinateWithBoundary boundary workerExecutionBoundary
            `shouldReturn` Left expected
          readIORef deleted `shouldReturn` [Nothing]

    it "binds Pod cleanup before attestation so an attestation refusal cannot strand it" $ do
      deleted <- newIORef ([] :: [Maybe (Text, TargetWorkerPodUid)])
      let invalidObservation =
            (rawWorkerObservation workerIntent)
              { observedTargetWorkerImageDigest = otherImageDigestText
              }
          boundary =
            standardWorkerBoundary
              { observeTargetWorkerIntent =
                  const (pure (Right (Just invalidObservation)))
              , deleteTargetWorkerIntent = \_ _ maybePod -> do
                  modifyIORef' deleted (++ [maybePod])
                  pure (Right ())
              }
      coordinateWithBoundary boundary workerExecutionBoundary
        `shouldReturn` Left
          ( TargetWorkerCoordinatorAttestationFailed
              TargetWorkerAttestationImageMismatch
          )
      readIORef deleted
        `shouldReturn` [Just ("target-secret-worker-pod", workerPodUid)]

    it "closes the retained session and deletes the exact Job/Pod after attach cancellation" $ do
      attachStarted <- newEmptyMVar :: IO (MVar ())
      attachBlocked <- newEmptyMVar :: IO (MVar ())
      result <-
        newEmptyMVar
          :: IO
               ( MVar
                   ( Either
                       AsyncException
                       (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
                   )
               )
      closed <- newIORef (0 :: Int)
      deleted <- newIORef (0 :: Int)
      absent <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ _ -> do
                  putMVar attachStarted ()
                  takeMVar attachBlocked
                  pure
                    ( Left
                        (TargetWorkerCoordinatorAttachFailed "unreachable")
                    )
              , deleteTargetWorkerIntent = \_ _ _ -> do
                  modifyIORef' deleted (+ 1)
                  pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ -> do
                  modifyIORef' absent (+ 1)
                  pure (Right True)
              }
          execution =
            workerExecutionBoundary
              { closeTargetWorkerSessionAttempt = \_ -> do
                  modifyIORef' closed (+ 1)
                  pure (Right ())
              }
      workerThread <-
        forkIO $ try (coordinateWithBoundary boundary execution) >>= putMVar result
      takeMVar attachStarted
      throwTo workerThread ThreadKilled
      takeMVar result `shouldReturn` Left ThreadKilled
      readIORef closed `shouldReturn` 1
      readIORef deleted `shouldReturn` 1
      readIORef absent `shouldReturn` 1

    it "Sprint 2.116 renders a secret-free, explicit-non-root, Guaranteed-QoS one-shot Job" $ do
      let job = mustRight (renderTargetSecretWorkerJob "registry/prodbox" 300 workerIntent)
          rendered =
            LazyByteString.toStrict
              (Aeson.encode job)
      ByteString.isInfixOf "target-secret-value" rendered `shouldBe` False
      ByteString.isInfixOf "prodbox-target-secret-worker" rendered `shouldBe` True
      ByteString.isInfixOf "sha256:" rendered `shouldBe` True
      ByteString.isInfixOf "automountServiceAccountToken\":false" rendered `shouldBe` True
      ByteString.isInfixOf "Memory" rendered `shouldBe` True
      ByteString.isInfixOf "stdinOnce\":true" rendered `shouldBe` True
      ByteString.isInfixOf "\"ephemeral-storage\":\"256Mi\"" rendered `shouldBe` True
      targetWorkerPodSecurityContext job
        `shouldBe` Just
          ( Aeson.object
              [ "runAsNonRoot" Aeson..= True
              , "runAsUser" Aeson..= (65532 :: Int)
              , "runAsGroup" Aeson..= (65532 :: Int)
              , "fsGroup" Aeson..= (65532 :: Int)
              , "fsGroupChangePolicy" Aeson..= ("OnRootMismatch" :: Text)
              , "seccompProfile"
                  Aeson..= Aeson.object ["type" Aeson..= ("RuntimeDefault" :: Text)]
              ]
          )

targetWorkerPodSecurityContext :: Aeson.Value -> Maybe Aeson.Value
targetWorkerPodSecurityContext (Aeson.Object root) = do
  Aeson.Object spec <- AesonKeyMap.lookup "spec" root
  Aeson.Object template <- AesonKeyMap.lookup "template" spec
  Aeson.Object podSpec <- AesonKeyMap.lookup "spec" template
  AesonKeyMap.lookup "securityContext" podSpec
targetWorkerPodSecurityContext _ = Nothing

agentDeploymentObservation
  :: TargetAgentIdentity -> Natural -> Natural -> Text -> ByteString.ByteString
agentDeploymentObservation identity generation observedGeneration rollout =
  agentDeploymentObservationWithTemplateDigest
    identity
    generation
    observedGeneration
    rollout

agentDeploymentObservationWithTemplateDigest
  :: TargetAgentIdentity -> Natural -> Natural -> Text -> ByteString.ByteString
agentDeploymentObservationWithTemplateDigest identity generation observedGeneration templateRollout =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= ("target-secret-agent" :: Text)
                  , "uid" Aeson..= ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text)
                  , "generation" Aeson..= generation
                  , "annotations"
                      Aeson..= Aeson.object
                        [ "prodbox.io/target-agent-identity"
                            Aeson..= targetAgentIdentityText identity
                        , "prodbox.io/target-agent-rollout-digest"
                            Aeson..= targetAgentRolloutDigest identity
                        ]
                  ]
            , "spec"
                Aeson..= Aeson.object
                  [ "template"
                      Aeson..= Aeson.object
                        [ "metadata"
                            Aeson..= Aeson.object
                              [ "annotations"
                                  Aeson..= Aeson.object
                                    [ "prodbox.io/target-agent-identity"
                                        Aeson..= targetAgentIdentityText identity
                                    , "prodbox.io/target-agent-rollout-digest"
                                        Aeson..= templateRollout
                                    ]
                              ]
                        ]
                  ]
            , "status"
                Aeson..= Aeson.object
                  ["observedGeneration" Aeson..= observedGeneration]
            ]
        )
    )

agentDeploymentObservationWithoutAnnotations
  :: Natural -> Natural -> ByteString.ByteString
agentDeploymentObservationWithoutAnnotations generation observedGeneration =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= ("target-secret-agent" :: Text)
                  , "uid" Aeson..= ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text)
                  , "generation" Aeson..= generation
                  ]
            , "spec"
                Aeson..= Aeson.object
                  [ "template"
                      Aeson..= Aeson.object
                        ["metadata" Aeson..= Aeson.object []]
                  ]
            , "status"
                Aeson..= Aeson.object
                  ["observedGeneration" Aeson..= observedGeneration]
            ]
        )
    )

serviceAccountObservation :: Text -> Text -> Text -> ByteString.ByteString
serviceAccountObservation name namespace uid =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= name
                  , "namespace" Aeson..= namespace
                  , "uid" Aeson..= uid
                  ]
            ]
        )
    )

nextCreateObservation
  :: IORef [Either Text (Maybe TargetWorkerJobUid)]
  -> IO (Either Text (Maybe TargetWorkerJobUid))
nextCreateObservation observations = do
  remaining <- readIORef observations
  case remaining of
    [] -> pure (Left "fixture observation exhausted")
    next : rest -> writeIORef observations rest >> pure next

standardWorkerBoundary :: TargetWorkerKubernetesBoundary IO
standardWorkerBoundary =
  TargetWorkerKubernetesBoundary
    { observeSelectedTargetAgentRollout = pure (Right workerAgentRollout)
    , createTargetWorkerIntent = const (pure (Right workerJobUid))
    , recoverTargetWorkerIntent =
        const (pure (Right (TargetWorkerCreateRecovered workerJobUid)))
    , observeTargetWorkerIntent =
        \intent -> pure (Right (Just (rawWorkerObservation intent)))
    , attachTargetWorkerIngress =
        \_ _ _ -> pure (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
    , deleteTargetWorkerIntent = \_ _ _ -> pure (Right ())
    , observeTargetWorkerIntentAbsent = \_ _ _ -> pure (Right True)
    }

coordinateWithBoundary
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateWithBoundary boundary execution =
  coordinateDirectTargetMaterialization
    boundary
    execution
    acceptedAuthority
    admissionTime
    workerAgentIdentity
    workerTarget
    TargetWorkerDirectAws
    workerImageDigest
    signedIntentBytes
    workerPayload

type TargetSessionStore = IORef (Int, ServiceSessionJournal)

newTargetSessionStore :: IO TargetSessionStore
newTargetSessionStore =
  newIORef
    ( 0
    , mustRight (mkInitialServiceSessionJournal targetSecretWorkerVaultRole)
    )

targetSessionRepository
  :: TargetSessionStore
  -> IORef [Text]
  -> ServiceSessionJournalRepository IO Int
targetSessionRepository store events =
  ServiceSessionJournalRepository
    { readServiceSessionJournal = do
        (revision, journal) <- readIORef store
        pure
          ( Right
              ServiceSessionJournalSnapshot
                { serviceSessionJournalRevision = revision
                , serviceSessionJournalObserved = journal
                }
          )
    , compareAndSwapServiceSessionJournal = \expected next -> do
        (revision, _) <- readIORef store
        if revision /= expected
          then pure (Left "fixture CAS conflict")
          else do
            writeIORef store (revision + 1, next)
            modifyIORef'
              events
              (++ ["journal:" <> targetSessionPhaseToken (serviceSessionJournalPhase next)])
            pure (Right ())
    }

targetSessionPhaseToken :: ServiceSessionPhase -> Text
targetSessionPhaseToken phase = case phase of
  ServiceSessionVacant _ -> "vacant"
  ServiceSessionAcquiring _ -> "acquiring"
  ServiceSessionPrecleaned _ -> "precleaned"
  ServiceSessionLoginAttemptCommitted _ -> "login-attempt-committed"
  ServiceSessionActive _ _ -> "active"
  ServiceSessionCleanupRequired _ _ -> "cleanup-required"
  ServiceSessionCleanupProven _ -> "cleanup-proven"

orderedTargetAuditOps :: IORef [Text] -> VaultAccessorAuditOps IO
orderedTargetAuditOps events =
  VaultAccessorAuditOps
    { auditListAccessors = do
        modifyIORef' events (++ ["audit:inventory"])
        pure (Right [])
    , auditLookupAccessor = \_ -> do
        modifyIORef' events (++ ["audit:lookup"])
        pure
          ( Right
              TokenAccessorInfo
                { tokenAccessorInfoPolicies = ["default", targetSecretWorkerVaultRole]
                , tokenAccessorInfoMetadata =
                    vaultAccessorSubjectMetadata
                      (targetWorkerActiveAccessorSubject (workerAttestation workerIntent))
                , tokenAccessorInfoCreationPath = "auth/kubernetes/login"
                , tokenAccessorInfoDisplayName = "kubernetes-target-secret-worker"
                }
          )
    , auditRevokeAccessor = const (pure (Right ()))
    , auditObserveAccessorAbsent = \_ -> do
        modifyIORef' events (++ ["audit:known-absence"])
        pure (Right True)
    , auditWaitVisibilityGrace = do
        modifyIORef' events (++ ["audit:grace"])
        pure (Right ())
    }

unusedTargetIntentAuthorityClient :: TargetIntentAuthorityClient IO
unusedTargetIntentAuthorityClient =
  error "Target intent Authority client must not be evaluated by journal-only test"

showPermitResult
  :: Either TargetWorkerExecutionPermitError VerifiedTargetWorkerExecutionPermit
  -> String
showPermitResult result = case result of
  Left err -> show err
  Right _ -> "Right VerifiedTargetWorkerExecutionPermit"

isLeftValue :: Either left right -> Bool
isLeftValue value = case value of
  Left _ -> True
  Right _ -> False

data VaultFixture = VaultFixture
  { vaultData :: !(IORef TargetWorkerDataObservation)
  , vaultMetadata :: !(IORef TargetWorkerMetadataObservation)
  , vaultCasWrites :: !(IORef Int)
  , vaultMetadataWrites :: !(IORef Int)
  , vaultLoseCasResponse :: !(IORef Bool)
  }

freshVaultFixture
  :: TargetWorkerDataObservation
  -> TargetWorkerMetadataObservation
  -> IO VaultFixture
freshVaultFixture initialData initialMetadata =
  VaultFixture
    <$> newIORef initialData
    <*> newIORef initialMetadata
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef False

runMaterialization
  :: VaultFixture
  -> IO (Either TargetWorkerExecutionError TargetWorkerMaterializationResult)
runMaterialization fixture =
  executeTargetWorkerMaterialization
    admissionTime
    (fixtureBoundary fixture)
    (workerAttestation workerIntent)
    workerPayload

fixtureBoundary :: VaultFixture -> TargetWorkerVaultBoundary IO
fixtureBoundary fixture =
  TargetWorkerVaultBoundary
    { targetWorkerReadData = const (Right <$> readIORef (vaultData fixture))
    , targetWorkerReadMetadata = const (Right <$> readIORef (vaultMetadata fixture))
    , targetWorkerCommitmentHmac = const (pure (Right workerCommitment))
    , targetWorkerCompareAndSwap = \_ expected fields -> do
        modifyIORef' (vaultCasWrites fixture) (+ 1)
        let version = expected + 1
        writeIORef (vaultData fixture) (TargetWorkerDataPresent version fields)
        lose <- readIORef (vaultLoseCasResponse fixture)
        pure $ if lose then Left "response lost" else Right version
    , targetWorkerWriteMetadata = \_ fields -> do
        modifyIORef' (vaultMetadataWrites fixture) (+ 1)
        observed <- readIORef (vaultData fixture)
        case observed of
          TargetWorkerDataMissing -> pure (Left "data missing")
          TargetWorkerDataPresent version _ -> do
            writeIORef
              (vaultMetadata fixture)
              (TargetWorkerMetadataPresent version fields)
            pure (Right ())
    }

workerIntent :: TargetWorkerIntent
workerIntent =
  mustRight
    ( prepareTargetWorkerIntent
        acceptedAuthority
        admissionTime
        workerAgentIdentity
        workerTarget
        TargetWorkerDirectAws
        workerImageDigest
        signedIntentBytes
    )

workerAttestation :: TargetWorkerIntent -> TargetWorkerAttestation
workerAttestation intent =
  mustAttestation (attestTargetWorkerPod admissionTime intent (rawWorkerObservation intent))

workerSessionBinding
  :: TargetWorkerAttestation -> ServiceSessionBinding
workerSessionBinding attestation =
  mustRight
    ( mkServiceSessionBinding
        targetSecretWorkerVaultRole
        (targetWorkerSessionOperationId (targetWorkerAttestedIntent attestation))
        (targetWorkerSessionAttemptId workerAgentRollout attestation)
        1
    )

workerExecutionPermit
  :: TargetWorkerAttestation -> IO VerifiedTargetWorkerExecutionPermit
workerExecutionPermit attestation = do
  signed <-
    issueTargetWorkerExecutionPermit
      permitSigner
      acceptedAuthority
      workerAgentRollout
      attestation
      (workerSessionBinding attestation)
  pure
    ( mustRight
        ( verifyTargetWorkerExecutionPermit
            acceptedAuthority
            admissionTime
            (targetWorkerAttestedIntent attestation)
            (mustRight signed)
        )
    )

workerExecutionBoundary :: TargetWorkerExecutionBoundary IO
workerExecutionBoundary =
  TargetWorkerExecutionBoundary
    { prepareTargetWorkerSessionAttempt =
        \_ attestation -> pure (Right (workerSessionBinding attestation))
    , authorizeTargetWorkerExecution =
        \accepted rollout attestation binding ->
          fmap
            (either (Left . Text.pack . show) Right)
            ( issueTargetWorkerExecutionPermit
                permitSigner
                accepted
                rollout
                attestation
                binding
            )
    , activateTargetWorkerSessionAttempt = \_ _ _ -> pure (Right ())
    , closeTargetWorkerSessionAttempt = const (pure (Right ()))
    }

permitSigner :: AuthorityManifestSigner IO
permitSigner =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey = pure (Left "unused in permit test")
    , signAuthorityManifestPayload = \payload ->
        pure $ do
          private <- case Ed25519.secretKey (ByteString.pack [0 .. 31]) of
            CryptoFailed _ -> Left "test signing key invalid"
            CryptoPassed key -> Right key
          let public = Ed25519.toPublic private
              signature = Ed25519.sign private public payload
          Right (1, ByteArray.convert signature)
    }

rawWorkerObservation :: TargetWorkerIntent -> RawTargetWorkerPodObservation
rawWorkerObservation intent =
  RawTargetWorkerPodObservation
    { observedTargetWorkerJobName = targetWorkerIntentJobName intent
    , observedTargetWorkerJobUid = "job-uid-123"
    , observedTargetWorkerPodName = "target-secret-worker-pod"
    , observedTargetWorkerPodUid = targetWorkerPodUidText workerPodUid
    , observedTargetWorkerImageDigest = targetWorkerImageDigestText workerImageDigest
    , observedTargetWorkerServiceAccount = targetWorkerIntentServiceAccount intent
    , observedTargetWorkerServiceAccountUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    , observedTargetWorkerTarget =
        targetSecretIdToken (targetWorkerIntentTarget intent)
    , observedTargetWorkerAgentIdentity = targetAgentIdentityText workerAgentIdentity
    , observedTargetWorkerSchema =
        targetWorkerSchemaToken (targetWorkerIntentSchema intent)
    , observedTargetWorkerRequestDigest =
        targetValueDigestText (targetWorkerIntentRequestDigest intent)
    , observedTargetWorkerDeadlineMicros = 1000
    , observedTargetWorkerPhase = "Running"
    , observedTargetWorkerReady = True
    , observedTargetWorkerRestartCount = 0
    , observedTargetWorkerDeletionTimestamp = Nothing
    }

workerPayload :: TargetSecretPayload
workerPayload =
  AwsCredentialMaterial
    { awsCredentialMaterialIdentity = AwsLifecycleProvider
    , awsCredentialMaterialAccessKeyId = "AKIAEXAMPLE"
    , awsCredentialMaterialSecretAccessKey = "target-secret-value"
    , awsCredentialMaterialSessionToken = ""
    , awsCredentialMaterialRegion = (fixtureAwsRegion FixtureCaCentral1)
    }

workerTarget :: TargetSecretId
workerTarget = TargetAwsCredential AwsLifecycleProvider

tlsWorkerTarget :: TargetSecretId
tlsWorkerTarget = TargetPublicEdgeTls

workerSink :: TargetClusterSecretSink
workerSink = mustRight (compiledTargetSecretSink workerTarget)

tlsWorkerSink :: TargetClusterSecretSink
tlsWorkerSink = mustRight (compiledTargetSecretSink tlsWorkerTarget)

workerSpec :: TargetCommittedIntentSpec
workerSpec =
  TargetCommittedIntentSpec
    { targetIntentIssuerGeneration = issuerGeneration
    , targetIntentIssuerIdentity = "lifecycle-authority"
    , targetIntentAuthorityEpoch = AuthorityEpoch 3
    , targetIntentOperationId = "target-operation"
    , targetIntentActionIndex = 0
    , targetIntentCommitReceiptDigest = sha256TargetValueDigest "provisioner-receipt"
    , targetIntentOwnerNonce = mustRight (mkOwnerNonce "authority-owner")
    , targetIntentFencingToken = mustRight (mkFencingToken 6)
    , targetIntentAgentIdentity = workerAgentIdentity
    , targetIntentSink = workerSink
    , targetIntentGeneration = workerGeneration
    , targetIntentDeadline = authorityTimeFromMicros 1000
    , targetIntentIdempotencyKey = "target-operation-generation-1"
    }

tlsWorkerSpec :: TargetCommittedIntentSpec
tlsWorkerSpec =
  workerSpec
    { targetIntentOperationId = "target-tls-prepare-operation"
    , targetIntentCommitReceiptDigest =
        targetWorkerOperationRequestDigest TargetWorkerTlsPrepareInput
    , targetIntentSink = tlsWorkerSink
    , targetIntentIdempotencyKey = "target-tls-prepare-generation-1"
    }

tlsWrongDigestSpec :: TargetCommittedIntentSpec
tlsWrongDigestSpec =
  tlsWorkerSpec
    { targetIntentCommitReceiptDigest =
        sha256TargetValueDigest "different-authorized-operation"
    }

acceptedAuthority :: AcceptedTargetAuthority
acceptedAuthority =
  mustRight
    ( mkAcceptedTargetAuthority
        issuerGeneration
        "lifecycle-authority"
        (targetIntentSigningPublicKey signingKey)
        (AuthorityEpoch 3)
        (mustRight (mkFencingToken 5))
        workerAgentIdentity
        workerSink
    )

tlsAcceptedAuthority :: AcceptedTargetAuthority
tlsAcceptedAuthority =
  mustRight
    ( mkAcceptedTargetAuthority
        issuerGeneration
        "lifecycle-authority"
        (targetIntentSigningPublicKey signingKey)
        (AuthorityEpoch 3)
        (mustRight (mkFencingToken 5))
        workerAgentIdentity
        tlsWorkerSink
    )

signedIntentBytes :: ByteString.ByteString
signedIntentBytes =
  encodeSignedTargetCommittedIntent
    ( signTargetCommittedIntent
        signingKey
        (mustRight (mkUnsignedTargetCommittedIntent workerSpec))
    )

tlsSignedIntentBytes :: ByteString.ByteString
tlsSignedIntentBytes =
  encodeSignedTargetCommittedIntent
    ( signTargetCommittedIntent
        signingKey
        (mustRight (mkUnsignedTargetCommittedIntent tlsWorkerSpec))
    )

tlsWorkerIntent :: TargetWorkerIntent
tlsWorkerIntent =
  mustRight
    ( prepareTargetWorkerIntent
        tlsAcceptedAuthority
        admissionTime
        workerAgentIdentity
        tlsWorkerTarget
        TargetWorkerTlsPrepare
        workerImageDigest
        tlsSignedIntentBytes
    )

tlsWrongDigestIntent :: TargetWorkerIntent
tlsWrongDigestIntent =
  mustRight
    ( prepareTargetWorkerIntent
        tlsAcceptedAuthority
        admissionTime
        workerAgentIdentity
        tlsWorkerTarget
        TargetWorkerTlsPrepare
        workerImageDigest
        ( encodeSignedTargetCommittedIntent
            ( signTargetCommittedIntent
                signingKey
                (mustRight (mkUnsignedTargetCommittedIntent tlsWrongDigestSpec))
            )
        )
    )

tlsWorkerAttestation :: TargetWorkerIntent -> TargetWorkerAttestation
tlsWorkerAttestation intent =
  mustAttestation (attestTargetWorkerPod admissionTime intent (rawWorkerObservation intent))

tlsWorkerExecutionPermit
  :: TargetWorkerAttestation -> IO VerifiedTargetWorkerExecutionPermit
tlsWorkerExecutionPermit attestation = do
  signed <-
    issueTargetWorkerExecutionPermit
      permitSigner
      tlsAcceptedAuthority
      workerAgentRollout
      attestation
      (workerSessionBinding attestation)
  pure
    ( mustRight
        ( verifyTargetWorkerExecutionPermit
            tlsAcceptedAuthority
            admissionTime
            (targetWorkerAttestedIntent attestation)
            (mustRight signed)
        )
    )

signingKey :: TargetIntentSigningKey
signingKey = mustRight (mkTargetIntentSigningKey (ByteString.pack [0 .. 31]))

issuerGeneration :: TargetIssuerKeyGeneration
issuerGeneration = mustRight (mkTargetIssuerKeyGeneration 1)

workerGeneration :: CredentialGeneration
workerGeneration = mustRight (mkCredentialGeneration 1)

workerAgentIdentity :: TargetAgentIdentity
workerAgentIdentity =
  mustRight
    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "a"))

priorWorkerAgentIdentity :: TargetAgentIdentity
priorWorkerAgentIdentity =
  mustRight
    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))

foreignWorkerAgentIdentity :: TargetAgentIdentity
foreignWorkerAgentIdentity =
  mustRight
    (mkTargetAgentIdentity ("foreign@sha256:" <> Text.replicate 64 "a"))

authorityForAgentAt :: TargetAgentIdentity -> AuthorityEpoch -> AcceptedTargetAuthority
authorityForAgentAt agentIdentity epoch =
  mustRight
    ( mkAcceptedTargetAuthority
        issuerGeneration
        "lifecycle-authority"
        (targetIntentSigningPublicKey signingKey)
        epoch
        (mustRight (mkFencingToken 5))
        agentIdentity
        workerSink
    )

workerAgentRollout :: TargetAgentRolloutEvidence
workerAgentRollout =
  mustRight
    ( mkTargetAgentRolloutEvidence
        workerAgentIdentity
        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        1
        1
        (targetAgentRolloutDigest workerAgentIdentity)
    )

workerImageDigest :: TargetWorkerImageDigest
workerImageDigest = mustRight (mkTargetWorkerImageDigest ("sha256:" <> Text.replicate 64 "a"))

otherImageDigestText :: Text
otherImageDigestText = "sha256:" <> Text.replicate 64 "b"

workerPodUid :: TargetWorkerPodUid
workerPodUid = mustRight (mkTargetWorkerPodUid "11111111-2222-3333-4444-555555555555")

workerServiceAccountUid :: TargetWorkerServiceAccountUid
workerServiceAccountUid =
  mustRight
    (mkTargetWorkerServiceAccountUid "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

workerJobUid :: TargetWorkerJobUid
workerJobUid = mustRight (mkTargetWorkerJobUid "job-uid-123")

workerCommitment :: Text
workerCommitment = "vault:v1:opaque-worker-commitment"

admissionTime :: AuthorityTime
admissionTime = authorityTimeFromMicros 100

mustAttestation
  :: Either TargetWorkerAttestationError TargetWorkerAttestation
  -> TargetWorkerAttestation
mustAttestation value = case value of
  Left err -> error (show err)
  Right result -> result

isApplied
  :: Either TargetWorkerExecutionError TargetWorkerMaterializationResult
  -> Bool
isApplied value = case value of
  Right TargetWorkerMaterializationApplied {} -> True
  _ -> False

isAlreadyApplied
  :: Either TargetWorkerExecutionError TargetWorkerMaterializationResult
  -> Bool
isAlreadyApplied value = case value of
  Right TargetWorkerMaterializationAlreadyApplied {} -> True
  _ -> False

isRecovered
  :: Either TargetWorkerExecutionError TargetWorkerMaterializationResult
  -> Bool
isRecovered value = case value of
  Right TargetWorkerMaterializationRecovered {} -> True
  _ -> False

prefixOf :: Text -> Text -> Bool
prefixOf = Text.isPrefixOf

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
