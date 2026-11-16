{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetSecretWorker
  ( controlPlaneTargetSecretWorkerSuite
  )
where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (forM_, unless)
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
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
import Prodbox.ControlPlane.ClosedSession (finishClosedSession)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , ServiceSessionDispatchState (..)
  , ServiceSessionEvent (..)
  , ServiceSessionJournal
  , ServiceSessionJournalError (..)
  , ServiceSessionJournalRepository (..)
  , ServiceSessionJournalSnapshot (..)
  , ServiceSessionPhase (..)
  , WireTargetWorkerAttemptBinding (..)
  , decodeServiceSessionJournal
  , encodeServiceSessionJournal
  , mkInitialServiceSessionJournal
  , mkServiceSessionBinding
  , mkServiceSessionCreationReservation
  , mkServiceSessionWorkload
  , mkServiceSessionWorkloadEvidence
  , serviceSessionBindingFence
  , serviceSessionCreationFence
  , serviceSessionJournalDispatchState
  , serviceSessionJournalPhase
  , serviceSessionJournalWorkload
  , serviceSessionJournalWorkloadEvidence
  , serviceSessionWorkloadEvidenceAttempt
  , serviceSessionWorkloadEvidenceWorkload
  , serviceSessionWorkloadJobName
  , serviceSessionWorkloadJobUid
  , serviceSessionWorkloadPodName
  , serviceSessionWorkloadPodUid
  , serviceSessionWorkloadServiceAccountUid
  , stepServiceSessionJournal
  )
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLifecycleError (..)
  )
import Prodbox.ControlPlane.TargetAuthorityEpoch
  ( TargetAuthorityEpochAction (PrepareTargetAuthorityEpoch)
  , initialTargetAuthorityEpochRecord
  , mkTargetAuthorityEpochContext
  , mkTargetAuthorityEpochPreparation
  , stepTargetAuthorityEpoch
  )
import Prodbox.ControlPlane.TargetAuthorityEpochCodec (encodeTargetAuthorityEpochFields)
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
  ( TargetWorkerJobConnection (..)
  , classifyTargetAgentRolloutExit
  , classifyTargetWorkerObjectAbsence
  , classifyTargetWorkerServiceAccountObservation
  , classifyTargetWorkerSessionPrepareError
  , parseTargetAgentRolloutObservation
  , parseTargetWorkerServiceAccountObservation
  , recoverTargetWorkerCreateWith
  , runtimeImageIdentityMatches
  , targetWorkerActiveAccessorSubject
  , targetWorkerAttachProvisionalFailureDetail
  , targetWorkerAttachTransportFailureDetail
  , targetWorkerKubernetesBoundary
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
  , authenticateTargetWorkerFrame
  , classifyTlsHomeRewrapWorkerResult
  , decodeTargetWorkerAcceptedAuthority
  , guardTargetWorkerAuditInventory
  , readTargetWorkerPodName
  , readTargetWorkerPodUid
  , readTargetWorkerProjectedToken
  , renderTargetSecretWorkerRuntimeRefusal
  , targetSecretWorkerTlsHomeRewrapRefusalTokens
  , targetWorkerServiceLoginAccepted
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( TargetWorkerExecutionPermitError (..)
  , VerifiedTargetWorkerExecutionPermit
  , decodeTargetWorkerExecutionPermit
  , encodeTargetWorkerExecutionPermit
  , encodeVerifiedTargetWorkerExecutionPermit
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
  , VaultAccessorLookupError (..)
  , VaultAccessorSubject (..)
  , classifyVaultAccessorLookupResponse
  , isBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  )
import Prodbox.Crypto.Aead (AeadError (AeadAuthenticationFailed))
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.Authority.EpochTopology (mkCutoverDigest)
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
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createNamedPipe
  , createSymbolicLink
  , ownerExecuteMode
  , ownerReadMode
  , ownerWriteMode
  , setFileMode
  , unionFileModes
  )
import System.Process qualified as Process
import System.Timeout (timeout)
import TestSupport

data AuditorFixtureLogin
  = AuditorFixtureInvalid
  | AuditorFixtureValid
  deriving stock (Eq, Show)

controlPlaneTargetSecretWorkerSuite :: SuiteBuilder ()
controlPlaneTargetSecretWorkerSuite =
  describe "Sprint 4.50 attested one-shot Target materializer" $ do
    it "bounds projected-token reads on the opened descriptor" $
      withSystemTempDirectory "prodbox-target-projection" $ \root -> do
        let tokenFile = root </> "token"
            projectedLink = root </> "projected-token"
            fifo = root </> "fifo"
            exact = Text.replicate 32768 "\x1f600"
        ByteString.writeFile tokenFile (TextEncoding.encodeUtf8 exact)
        createSymbolicLink tokenFile projectedLink
        readTargetWorkerProjectedToken projectedLink `shouldReturn` Right exact
        ByteString.writeFile tokenFile (ByteString.replicate 32769 120)
        readTargetWorkerProjectedToken tokenFile `shouldReturn` Left "projected token is too large"
        ByteString.writeFile tokenFile (ByteString.replicate (4 * 32768 + 1) 120)
        readTargetWorkerProjectedToken tokenFile `shouldReturn` Left "projected token is too large"
        ByteString.writeFile tokenFile (ByteString.pack [255])
        readTargetWorkerProjectedToken tokenFile `shouldReturn` Left "projected token is not valid UTF-8"
        ByteString.writeFile tokenFile " \n"
        readTargetWorkerProjectedToken tokenFile `shouldReturn` Left "projected token is empty"
        createNamedPipe fifo (ownerReadMode `unionFileModes` ownerWriteMode)
        timeout 5000000 (readTargetWorkerProjectedToken fifo)
          `shouldReturn` Just (Left "projected token path is not a regular file")
    it "bounds projected Pod-identity reads and retains line-ending support" $
      withSystemTempDirectory "prodbox-target-identity" $ \root -> do
        let identityFile = root </> "identity"
            fifo = root </> "fifo"
            uid = Text.replicate 128 "u"
            name = Text.replicate 253 "n"
        ByteString.writeFile identityFile (TextEncoding.encodeUtf8 (uid <> "\r\n"))
        readTargetWorkerPodUid identityFile `shouldReturn` Right (mustRight (mkTargetWorkerPodUid uid))
        ByteString.writeFile identityFile (TextEncoding.encodeUtf8 (name <> "\n"))
        readTargetWorkerPodName identityFile `shouldReturn` Right name
        ByteString.writeFile identityFile (ByteString.replicate 131 117)
        readTargetWorkerPodUid identityFile `shouldReturn` Left TargetSecretWorkerPodUidInvalid
        ByteString.writeFile identityFile (ByteString.replicate 256 110)
        readTargetWorkerPodName identityFile `shouldReturn` Left TargetSecretWorkerPodNameInvalid
        createNamedPipe fifo (ownerReadMode `unionFileModes` ownerWriteMode)
        timeout 5000000 (readTargetWorkerPodUid fifo)
          `shouldReturn` Just (Left TargetSecretWorkerPodUidReadFailed)
        timeout 5000000 (readTargetWorkerPodName fifo)
          `shouldReturn` Just (Left TargetSecretWorkerPodNameReadFailed)
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
                   , "attach-failed/completion-frame-read-unavailable"
                   , "attach-failed/completion-stderr-read-unavailable"
                   , "attach-failed/completion-trailing-stdout-read-unavailable"
                   , "attach-failed/completion-process-wait-unavailable"
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
    it
      "CASCADE-QUALIFICATION-TLS-SESSION-CLEANUP-ACCESSOR-AUDIT-CAUSE-DISCARDED-2026-09-24 refines retained session cleanup to one closed value-free stage"
      $ do
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
        map
          ( diagnostic
              . Text.pack
              . show
              . ServiceSessionLifecycleCleanupFailed
          )
          [ VaultAccessorAuditIdentityInvalid
          , VaultAccessorObservationFailed
          , VaultAccessorClassificationUnavailable
          , VaultAccessorClassificationFailed
          , VaultAccessorVisibilityWaitFailed
          , VaultAccessorStableAbsenceFailed
          ]
          `shouldBe` [ "session-cleanup-failed/accessor-audit/identity-invalid"
                     , "session-cleanup-failed/accessor-audit/observation-failed"
                     , "session-cleanup-failed/accessor-audit/classification-unavailable"
                     , "session-cleanup-failed/accessor-audit/classification-failed"
                     , "session-cleanup-failed/accessor-audit/visibility-wait-failed"
                     , "session-cleanup-failed/accessor-audit/stable-absence-failed"
                     ]
        diagnostic "ServiceSessionLifecycleCleanupFailed private-detail"
          `shouldBe` "session-cleanup-failed/accessor-audit/unrecognized"
        diagnostic "private-detail" `shouldBe` "session-cleanup-failed/unrecognized"

    it
      "TLS-RETENTION-SELECTED-RESTORE-SESSION-PRECLEAN-FAILED-2026-09-04 reads Vault's answer for an accessor that vanished after inventory, passes over it, and keeps an unavailable lookup fatal"
      $ do
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
                     , "session-prepare-failed/preclean/classification-unavailable"
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
                     , "session-prepare-failed/recovery-completed-retry-required"
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
          , VaultAccessorClassificationUnavailable
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
                     , TargetWorkerSessionPreparePrecleanClassificationUnavailable
                     , TargetWorkerSessionPreparePrecleanClassificationFailed
                     , TargetWorkerSessionPreparePrecleanKnownIdentityMismatch
                     , TargetWorkerSessionPreparePrecleanRevocationFailed
                     , TargetWorkerSessionPreparePrecleanVisibilityWaitFailed
                     , TargetWorkerSessionPreparePrecleanStableAbsenceFailed
                     ]
        let privatePayload = "private-vault-response-body"
            -- The body Vault 1.18.3 returned on 2026-10-12 for an accessor that
            -- was never issued, was revoked, or had expired.
            vaultInvalidAccessor =
              "{\"errors\":[\"1 error occurred:\\n\\t* invalid accessor\\n\\n\"]}"
        classifyVaultAccessorLookupResponse (Left (HttpStatus 400 vaultInvalidAccessor))
          `shouldBe` Left VaultAccessorLookupAbsent
        -- Vault sends no 404 for this lookup, and no other failure is the
        -- absence answer: each stays unavailable and fails the audit.
        map
          classifyVaultAccessorLookupResponse
          [ Left (HttpStatus 404 privatePayload)
          , Left (HttpStatus 404 vaultInvalidAccessor)
          , Left (HttpStatus 400 privatePayload)
          , Left (HttpStatus 400 "{\"errors\":[\"missing accessor\"]}")
          , Left (HttpStatus 403 "{\"errors\":[\"permission denied\"]}")
          , Left (HttpConnectionFailure privatePayload)
          , Left (HttpTimeout privatePayload)
          , Left (HttpStatus 503 privatePayload)
          , Left (HttpDecode privatePayload)
          ]
          `shouldBe` replicate 9 (Left VaultAccessorLookupUnavailable)
        let auditWith lookupFailure =
              VaultAccessorAuditOps
                { auditListAccessors = pure (Right ["racing-accessor"])
                , auditLookupAccessor = \_ -> pure (Left lookupFailure)
                , auditRevokeAccessor = \_ -> pure (Right ())
                , auditObserveAccessorAbsent = \_ -> pure (Right True)
                , auditWaitVisibilityGrace = pure (Right ())
                }
        -- A vanished accessor is no member of the subject, so the proof completes.
        revokeAndProveVaultAccessorSubjectAbsent
          (auditWith VaultAccessorLookupAbsent)
          targetWorkerRoleWideAccessorSubject
          Nothing
          `shouldReturn` Right ()
        revokeAndProveVaultAccessorSubjectAbsent
          (auditWith VaultAccessorLookupUnavailable)
          targetWorkerRoleWideAccessorSubject
          Nothing
          `shouldReturn` Left VaultAccessorClassificationUnavailable

    it
      "CASCADE-QUALIFICATION-TLS-RETAIN-PROVISIONAL-FAILURE-CAUSE-DISCARDED-2026-09-24 retains only an exact bounded worker refusal while the superseded stage and arbitrary output stay generic"
      $ do
        let diagnostic detail =
              renderTargetWorkerCoordinatorDiagnostic
                (TargetWorkerCoordinatorAttachFailed detail)
            superseded =
              diagnostic
                (targetWorkerAttachTransportFailureDetail FramedExchangeProvisionalRead)
        superseded `shouldBe` "attach-failed/provisional-read-unavailable"
        let output =
              ProcessOutput
                (ExitFailure 1)
                ""
                "target-secret worker refused: TargetSecretWorkerVaultSessionCleanupUnavailable\n"
        diagnostic (targetWorkerAttachProvisionalFailureDetail output)
          `shouldBe` "attach-failed/provisional-read-unavailable/worker-vault-session-cleanup-unavailable"
        let arbitrary =
              output
                { processStderr =
                    processStderr output <> "private-provider-detail"
                }
        diagnostic (targetWorkerAttachProvisionalFailureDetail arbitrary)
          `shouldBe` "attach-failed/provisional-read-unavailable"
        Text.unpack (diagnostic (targetWorkerAttachProvisionalFailureDetail arbitrary))
          `shouldNotContain` "private-provider-detail"

    it
      "CASCADE-QUALIFICATION-TLS-HOME-PREPARE-ATTACH-COMPLETION-COLLECTION-UNAVAILABLE-2026-09-24 selects a missing terminal acknowledgement at the closed final-frame stage"
      $ do
        result <-
          captureSubprocessFramedExchangeBounded
            (BoundedSubprocessLimits 64 64 64 1000000)
            "frame"
            (\provisional -> pure (Right (ByteString.empty, provisional)))
            ( Subprocess
                "/bin/sh"
                [ "-c"
                , "head -c 9 >/dev/null; printf '\\000\\000\\000\\002ok'; head -c 4 >/dev/null"
                ]
                Nothing
                Nothing
            )
            :: IO
                 ( Either
                     (FramedSubprocessExchangeError ())
                     (ByteString.ByteString, ProcessOutput)
                 )
        case result of
          Left
            ( FramedSubprocessExchangeTransportError
                FramedExchangeCompletionFrameRead
                _
              ) -> pure ()
          _ -> expectationFailure "expected closed completion-frame-read transport stage"

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

    it "authenticates the exact frame before an auditor can preclean" $ do
      let attestation = workerAttestation workerIntent
      permit <- workerExecutionPermit attestation
      let encoded = mustRight (encodeDirectTargetWorkerIngress permit attestation workerPayload)
          permitBytes = encodeVerifiedTargetWorkerExecutionPermit permit
          (prefix, suffix) = ByteString.breakSubstring permitBytes encoded
          corrupted = ByteString.init permitBytes <> ByteString.singleton (ByteString.last permitBytes `xor` 1)
          forged = prefix <> corrupted <> ByteString.drop (ByteString.length permitBytes) suffix
          authenticate input =
            withTargetWorkerOperationIngress input $ \binding _ ->
              authenticateTargetWorkerFrame
                admissionTime
                acceptedAuthority
                workerAgentIdentity
                workerPodUid
                "target-secret-worker-pod"
                binding
      ByteString.null suffix `shouldBe` False
      case authenticate encoded of
        Right (Right (_, sessionBinding)) -> sessionBinding `shouldBe` workerSessionBinding attestation
        _ -> expectationFailure "valid bound frame was refused"
      case authenticate forged of
        Right (Left (TargetSecretWorkerExecutionPermitRejected TargetWorkerExecutionPermitSignatureInvalid)) -> pure ()
        _ -> expectationFailure "forged bound frame reached preclean admission"

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

    it "exposes a delayed metadata write overwriting a successor after data readback" $ do
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      let base = fixtureBoundary fixture
          successorMetadata = Map.fromList [("prodbox_generation", "2"), ("prodbox_commitment", "vault:v1:successor")]
          delayed =
            base
              { targetWorkerWriteMetadata = \target fields -> do
                  writeIORef (vaultData fixture) (TargetWorkerDataPresent 2 (Map.singleton "successor" "value"))
                  writeIORef (vaultMetadata fixture) (TargetWorkerMetadataPresent 2 successorMetadata)
                  targetWorkerWriteMetadata base target fields
              }
      result <-
        executeTargetWorkerMaterialization
          admissionTime
          delayed
          (workerAttestation workerIntent)
          workerPayload
      result `shouldBe` Left TargetWorkerExecutionMetadataReadBackMismatch
      observed <- readIORef (vaultMetadata fixture)
      case observed of
        TargetWorkerMetadataPresent 2 fields -> do
          Map.lookup "prodbox_generation" fields `shouldBe` Just "1"
          fields `shouldNotBe` successorMetadata
        _ -> expectationFailure "expected successor data with overwritten metadata"
      beforeCas <- readIORef (vaultCasWrites fixture)
      beforeMetadata <- readIORef (vaultMetadataWrites fixture)
      runMaterialization fixture `shouldReturn` Left TargetWorkerExecutionMetadataInvalid
      readIORef (vaultCasWrites fixture) `shouldReturn` beforeCas
      readIORef (vaultMetadataWrites fixture) `shouldReturn` beforeMetadata

    it "refuses malformed or stale explicit metadata version bindings" $ do
      let custom version =
            Map.fromList
              [ (targetMaterialMetadataVaultVersionField, version)
              , ("prodbox_generation", "1")
              , ("prodbox_commitment", workerCommitment)
              ]
      forM_ ["0", "1", "02", "bad"] $ \version -> do
        fixture <-
          freshVaultFixture TargetWorkerDataMissing (TargetWorkerMetadataPresent 2 (custom version))
        runMaterialization fixture `shouldReturn` Left TargetWorkerExecutionMetadataInvalid
        readIORef (vaultCasWrites fixture) `shouldReturn` 0
        readIORef (vaultMetadataWrites fixture) `shouldReturn` 0

    it "shows that a prepared trust row does not stop a worker holding earlier authority" $ do
      let initial = mustRight (initialTargetAuthorityEpochRecord workerTarget (Just acceptedAuthority))
          initialFields = mustRight (encodeTargetAuthorityEpochFields initial)
          cached = mustRight (decodeTargetWorkerAcceptedAuthority workerTarget initialFields)
          intent =
            mustRight
              ( prepareTargetWorkerIntent
                  cached
                  admissionTime
                  workerAgentIdentity
                  workerTarget
                  TargetWorkerDirectAws
                  workerImageDigest
                  signedIntentBytes
              )
          attestation = workerAttestation intent
          successor =
            mustRight
              ( mkAcceptedTargetAuthority
                  issuerGeneration
                  "lifecycle-authority"
                  (targetIntentSigningPublicKey signingKey)
                  (AuthorityEpoch 4)
                  (mustRight (mkFencingToken 5))
                  workerAgentIdentity
                  workerSink
              )
          context =
            mustRight
              ( mkTargetAuthorityEpochContext
                  3
                  4
                  (fromJust (mkCutoverDigest (Text.replicate 64 "a")))
                  (authorityTimeFromMicros 1000)
              )
          preparation = mustRight (mkTargetAuthorityEpochPreparation context successor)
          frozen =
            mustRight
              ( stepTargetAuthorityEpoch
                  (AuthorityEpoch 3)
                  admissionTime
                  (PrepareTargetAuthorityEpoch preparation)
                  initial
              )
      decodeTargetWorkerAcceptedAuthority
        workerTarget
        (mustRight (encodeTargetAuthorityEpochFields frozen))
        `shouldBe` Left TargetSecretWorkerTrustUnavailable
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      executeTargetWorkerMaterialization admissionTime (fixtureBoundary fixture) attestation workerPayload
        >>= (`shouldSatisfy` isApplied)
      readIORef (vaultCasWrites fixture) `shouldReturn` 1

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
              , prepareTargetWorkerJob = \intent -> pure (prepareTargetSecretWorkerJob "registry/prodbox" 300 intent)
              , createTargetWorkerIntent = \_ _ -> pure (Right workerJobUid)
              , recoverTargetWorkerIntent =
                  const (pure (Right (TargetWorkerCreateRecovered workerJobUid)))
              , observeTargetWorkerIntent =
                  \intent -> pure (Right (Just (rawWorkerObservation intent)))
              , attachTargetWorkerIngress =
                  \_ _ _ ->
                    pure
                      (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
              , observeRetiredTargetWorkerAbsent = const (pure (Right True))
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
          (pure (Right admissionTime))
          workerAgentIdentity
          workerTarget
          TargetWorkerDirectAws
          workerImageDigest
          signedIntentBytes
          workerPayload
      result `shouldBe` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef deleted `shouldReturn` 1
      readIORef absent `shouldReturn` 1

    it "refuses stale or unavailable coordinator clocks without advancing the next effect" $ do
      map
        (renderTargetWorkerCoordinatorDiagnostic . TargetWorkerCoordinatorClockFailed)
        [TargetWorkerClockUnavailable, TargetWorkerClockRegressed, TargetWorkerClockDeadlineReached]
        `shouldBe` ["clock/unavailable", "clock/regressed", "clock/deadline-reached"]
      let valid = Right admissionTime
          expired = Right (authorityTimeFromMicros 1000)
          regressed = Right (authorityTimeFromMicros 99)
          stages =
            [ []
            , ["issue"]
            , ["issue", "create"]
            , ["issue", "create", "authorize", "delete", "close"]
            , ["issue", "create", "authorize", "dispatch", "delete"]
            ]
          failures =
            [ (Left "clock", TargetWorkerClockUnavailable)
            , (regressed, TargetWorkerClockRegressed)
            , (expired, TargetWorkerClockDeadlineReached)
            ]
          cases =
            [ (replicate stage valid ++ [failure], detail, expectedEvents)
            | (stage, expectedEvents) <- zip [0 ..] stages
            , (failure, detail) <- failures
            ]
              ++ [
                   ( [valid, valid, Right (authorityTimeFromMicros 101), valid]
                   , TargetWorkerClockRegressed
                   , ["issue", "create", "authorize", "delete", "close"]
                   )
                 ]
      forM_ cases $ \(observations, detail, expectedEvents) -> do
        remaining <- newIORef observations
        events <- newIORef ([] :: [Text])
        let readClock = do
              values <- readIORef remaining
              case values of
                [] -> pure (Left "fixture exhausted")
                value : rest -> writeIORef remaining rest >> pure value
            record label = modifyIORef' events (++ [label])
            boundary =
              standardWorkerBoundary
                { createTargetWorkerIntent = \intent job ->
                    record "create" >> createTargetWorkerIntent standardWorkerBoundary intent job
                , attachTargetWorkerIngress = \_ _ _ ->
                    record "attach" >> pure (Left (TargetWorkerCoordinatorAttachFailed "unexpected attach"))
                , deleteTargetWorkerIntent = \_ _ _ -> record "delete" >> pure (Right ())
                }
            execution =
              workerExecutionBoundary
                { issueTargetWorkerCreation = \reservation ->
                    record "issue" >> issueTargetWorkerCreation workerExecutionBoundary reservation
                , authorizeTargetWorkerExecution = \accepted rollout attestation binding -> do
                    record "authorize"
                    authorizeTargetWorkerExecution workerExecutionBoundary accepted rollout attestation binding
                , beginTargetWorkerDispatch = \binding ->
                    record "dispatch" >> beginTargetWorkerDispatch workerExecutionBoundary binding
                , closeTargetWorkerSessionAttempt = \_ -> record "close" >> pure (Right ())
                }
        coordinateWithClock boundary execution readClock
          `shouldReturn` Left (TargetWorkerCoordinatorClockFailed detail)
        readIORef events `shouldReturn` expectedEvents

    it "fails closed on clock exceptions and propagates cancellation" $ do
      coordinateWithClock
        standardWorkerBoundary
        workerExecutionBoundary
        (ioError (userError "clock failure"))
        `shouldReturn` Left (TargetWorkerCoordinatorClockFailed TargetWorkerClockUnavailable)
      cancelled <-
        try (coordinateWithClock standardWorkerBoundary workerExecutionBoundary (throwIO ThreadKilled))
      cancelled
        `shouldBe` (Left ThreadKilled :: Either AsyncException (Either TargetWorkerCoordinatorError TargetWorkerReceipt))
      asyncCancelled <-
        try (coordinateWithClock standardWorkerBoundary workerExecutionBoundary (throwIO AsyncCancelled))
      case asyncCancelled of
        Left AsyncCancelled -> pure ()
        Right _ -> expectationFailure "asynchronous clock cancellation was swallowed"

    it "retains the session after an ambiguous attach failure even when the workload is absent" $ do
      events <- newIORef ([] :: [Text])
      let boundary =
            standardWorkerBoundary
              { deleteTargetWorkerIntent = \_ _ _ ->
                  modifyIORef' events (++ ["delete"]) >> pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ ->
                  modifyIORef' events (++ ["absent"]) >> pure (Right True)
              }
          execution =
            workerExecutionBoundary
              { closeTargetWorkerSessionAttempt = \_ ->
                  modifyIORef' events (++ ["session-close"]) >> pure (Right ())
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef events `shouldReturn` ["delete", "absent"]

    it "closes a retired session when authorization fails before dispatch" $ do
      closes <- newIORef (0 :: Int)
      let execution =
            workerExecutionBoundary
              { authorizeTargetWorkerExecution = \_ _ _ _ -> pure (Left "unavailable")
              , closeTargetWorkerSessionAttempt = \_ ->
                  modifyIORef' closes (+ 1) >> pure (Right ())
              }
      coordinateWithBoundary standardWorkerBoundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorPermitUnavailable "unavailable")
      readIORef closes `shouldReturn` 1

    it "keeps the session lane occupied when worker absence cannot be proved" $ do
      events <- newIORef ([] :: [Text])
      let boundary =
            standardWorkerBoundary
              { deleteTargetWorkerIntent = \_ _ _ ->
                  modifyIORef' events (++ ["delete"]) >> pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ ->
                  modifyIORef' events (++ ["absent"]) >> pure (Right False)
              }
          execution =
            workerExecutionBoundary
              { authorizeTargetWorkerExecution = \_ _ _ _ -> pure (Left "unavailable")
              , recordTargetWorkerRetirement = \_ _ ->
                  modifyIORef' events (++ ["retirement-record"]) >> pure (Right ())
              , closeTargetWorkerSessionAttempt = \_ ->
                  modifyIORef' events (++ ["session-close"]) >> pure (Right ())
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left TargetWorkerCoordinatorStillPresent
      readIORef events `shouldReturn` ["delete", "absent"]

    it "keeps the session lane when worker deletion is refused" $ do
      closes <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { deleteTargetWorkerIntent = \_ _ _ -> pure (Left "delete unavailable")
              }
          execution =
            workerExecutionBoundary
              { closeTargetWorkerSessionAttempt = \_ ->
                  modifyIORef' closes (+ 1) >> pure (Right ())
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorDeleteFailed "delete unavailable")
      readIORef closes `shouldReturn` 0

    it "does not delete a shared workload after an occupied or ambiguous session preparation" $ do
      forM_ [TargetWorkerSessionPrepareRoleOccupied, TargetWorkerSessionPrepareJournalWriteFailed] $ \cause -> do
        events <- newIORef ([] :: [Text])
        let boundary =
              standardWorkerBoundary
                { attachTargetWorkerIngress = \_ _ _ ->
                    modifyIORef' events (++ ["attach"])
                      >> pure (Left (TargetWorkerCoordinatorAttachFailed "unexpected"))
                , deleteTargetWorkerIntent = \_ _ _ ->
                    modifyIORef' events (++ ["delete"]) >> pure (Right ())
                , observeTargetWorkerIntentAbsent = \_ _ _ ->
                    modifyIORef' events (++ ["absent"]) >> pure (Right True)
                }
            execution =
              workerExecutionBoundary
                { prepareTargetWorkerSessionAttempt = \_ _ _ -> pure (Left cause)
                , closeTargetWorkerSessionAttempt = \_ ->
                    modifyIORef' events (++ ["session-close"]) >> pure (Right ())
                }
        coordinateWithBoundary boundary execution
          `shouldReturn` Left (TargetWorkerCoordinatorSessionPrepareFailed cause)
        readIORef events `shouldReturn` []

    it "does not let a refused concurrent coordinator delete the winner's live workload" $ do
      started <- newEmptyMVar
      resume <- newEmptyMVar
      firstResult <- newEmptyMVar
      prepareCount <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ _ -> do
                  putMVar started ()
                  takeMVar resume
                  pure (Left (TargetWorkerCoordinatorAttachFailed "attach ended"))
              , deleteTargetWorkerIntent = \_ _ _ ->
                  modifyIORef' deletes (+ 1) >> pure (Right ())
              }
          execution =
            workerExecutionBoundary
              { prepareTargetWorkerSessionAttempt = \_ _ attestation -> do
                  count <- readIORef prepareCount
                  modifyIORef' prepareCount (+ 1)
                  pure $
                    if count == 0
                      then Right (workerSessionBinding attestation)
                      else Left TargetWorkerSessionPrepareRoleOccupied
              }
      _ <- forkIO (coordinateWithBoundary boundary execution >>= putMVar firstResult)
      takeMVar started
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareRoleOccupied)
      readIORef deletes `shouldReturn` 0
      putMVar resume ()
      takeMVar firstResult `shouldReturn` Left (TargetWorkerCoordinatorAttachFailed "attach ended")
      readIORef deletes `shouldReturn` 1

    it "does not delete a winner's workload when a concurrent observation fails" $ do
      started <- newEmptyMVar
      resume <- newEmptyMVar
      firstResult <- newEmptyMVar
      observations <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { observeTargetWorkerIntent = \intent -> do
                  count <- readIORef observations
                  modifyIORef' observations (+ 1)
                  pure $
                    if count == 0
                      then Right (Just (rawWorkerObservation intent))
                      else Left "observation unavailable"
              , attachTargetWorkerIngress = \_ _ _ -> do
                  putMVar started ()
                  takeMVar resume
                  pure (Left (TargetWorkerCoordinatorAttachFailed "attach ended"))
              , deleteTargetWorkerIntent = \_ _ _ ->
                  modifyIORef' deletes (+ 1) >> pure (Right ())
              }
      _ <- forkIO (coordinateWithBoundary boundary workerExecutionBoundary >>= putMVar firstResult)
      takeMVar started
      coordinateWithBoundary boundary workerExecutionBoundary
        `shouldReturn` Left (TargetWorkerCoordinatorObservationFailed "observation unavailable")
      readIORef deletes `shouldReturn` 0
      putMVar resume ()
      takeMVar firstResult `shouldReturn` Left (TargetWorkerCoordinatorAttachFailed "attach ended")
      readIORef deletes `shouldReturn` 1

    it "does not release an ambiguous predecessor using an accessor scan alone" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let binding = workerSessionBinding (workerAttestation workerIntent)
          initial = mustRight (mkInitialServiceSessionJournal targetSecretWorkerVaultRole)
          acquiring = mustRight (stepServiceSessionJournal (BeginServiceSessionAcquisition binding) initial)
          precleaned = mustRight (stepServiceSessionJournal (CommitServiceSessionPrecleaned binding) acquiring)
          committed = mustRight (stepServiceSessionJournal (CommitServiceSessionLoginAttempt binding) precleaned)
          execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
      writeIORef store (3, committed)
      reserveTargetWorkerCreation execution workerIntent
        `shouldReturn` Left TargetWorkerSessionPrepareRoleOccupied
      (_, retainedJournal) <- readIORef store
      serviceSessionJournalPhase retainedJournal `shouldBe` ServiceSessionLoginAttemptCommitted binding
      readIORef events `shouldReturn` []

    it "refuses a delayed worker inventory after a successor is issued" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      listed <- newEmptyMVar
      resume <- newEmptyMVar
      result <- newEmptyMVar
      revocations <- newIORef ([] :: [Text])
      let repository = targetSessionRepository store events
          execution =
            targetWorkerRetainedExecutionBoundary
              repository
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
          delayedAudit =
            (orderedTargetAuditOps events)
              { auditListAccessors = do
                  putMVar listed ()
                  takeMVar resume
                  pure (Right ["successor-accessor"])
              , auditRevokeAccessor = \accessor -> do
                  modifyIORef' revocations (++ [accessor])
                  pure (Right ())
              }
      firstReservation <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
      issueTargetWorkerCreation execution firstReservation `shouldReturn` Right ()
      firstBinding <-
        fmap
          mustRight
          (prepareTargetWorkerSessionAttempt execution firstReservation workerAgentRollout attestation)
      beginTargetWorkerDispatch execution firstBinding `shouldReturn` Right ()
      auditListAccessors
        (guardTargetWorkerAuditInventory repository firstBinding (orderedTargetAuditOps events))
        `shouldReturn` Right []
      let unavailable = repository {readServiceSessionJournal = pure (Left "unavailable")}
      fmap
        isLeftValue
        ( auditListAccessors
            (guardTargetWorkerAuditInventory unavailable firstBinding (orderedTargetAuditOps events))
        )
        `shouldReturn` True
      _ <- forkIO $ do
        audited <-
          revokeAndProveVaultAccessorSubjectAbsent
            (guardTargetWorkerAuditInventory repository firstBinding delayedAudit)
            targetWorkerRoleWideAccessorSubject
            Nothing
        putMVar result audited
      takeMVar listed
      activateTargetWorkerSessionAttempt execution attestation firstBinding "old-accessor"
        `shouldReturn` Right ()
      auditListAccessors
        (guardTargetWorkerAuditInventory repository firstBinding (orderedTargetAuditOps events))
        `shouldReturn` Right []
      settleTargetWorkerDispatch execution firstBinding `shouldReturn` Right ()
      recordTargetWorkerRetirement execution attestation firstBinding `shouldReturn` Right ()
      closeTargetWorkerSessionAttempt execution firstBinding `shouldReturn` Right ()
      secondReservation <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
      issueTargetWorkerCreation execution secondReservation `shouldReturn` Right ()
      secondBinding <-
        fmap
          mustRight
          (prepareTargetWorkerSessionAttempt execution secondReservation workerAgentRollout attestation)
      secondBinding `shouldNotBe` firstBinding
      beginTargetWorkerDispatch execution secondBinding `shouldReturn` Right ()
      putMVar resume ()
      takeMVar result `shouldReturn` Left VaultAccessorObservationFailed
      readIORef revocations `shouldReturn` []

    it "admits only one concurrent creator through the retained reservation" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      firstResult <- newEmptyMVar
      creates <- newIORef (0 :: Int)
      let retained =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution =
            retained {authorizeTargetWorkerExecution = authorizeTargetWorkerExecution workerExecutionBoundary}
          boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = \_ _ -> do
                  modifyIORef' creates (+ 1)
                  putMVar entered ()
                  takeMVar resume
                  pure (Right workerJobUid)
              }
      _ <- forkIO (coordinateWithBoundary boundary execution >>= putMVar firstResult)
      takeMVar entered
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareRoleOccupied)
      readIORef creates `shouldReturn` 1
      putMVar resume ()
      takeMVar firstResult `shouldReturn` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef creates `shouldReturn` 1

    it "records the exact Job reservation before invoking create" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let retained =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution =
            retained {authorizeTargetWorkerExecution = authorizeTargetWorkerExecution workerExecutionBoundary}
          boundary =
            standardWorkerBoundary
              { prepareTargetWorkerJob = \intent ->
                  modifyIORef' events (++ ["job:prepare"])
                    >> pure (prepareTargetSecretWorkerJob "registry/prodbox" 300 intent)
              , createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      observed <- readIORef events
      take 5 observed
        `shouldBe` ["journal:reserved", "job:prepare", "journal:creation-issued", "job:create", "journal:acquiring"]

    it "recovers a prepared reservation when Job preparation fails before issue" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          boundary =
            standardWorkerBoundary
              { prepareTargetWorkerJob = \_ -> modifyIORef' events (++ ["job:prepare"]) >> pure (Left "unavailable")
              , createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorCreateFailed "Target worker Job preparation failed")
      readIORef events `shouldReturn` ["journal:reserved", "job:prepare"]
      recoverRetiredTargetWorker
        execution
        (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
        `shouldReturn` Right True
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1

    it "retains the correct journal phase when a fresh clock expires" $ do
      forM_ [0, 1, 4] $ \expiryStage -> do
        store <- newTargetSessionStore
        events <- newIORef ([] :: [Text])
        readings <- newIORef (replicate expiryStage admissionTime ++ [authorityTimeFromMicros 1000])
        let retained =
              targetWorkerRetainedExecutionBoundary
                (targetSessionRepository store events)
                (orderedTargetAuditOps events)
                unusedTargetIntentAuthorityClient
            execution =
              retained {authorizeTargetWorkerExecution = authorizeTargetWorkerExecution workerExecutionBoundary}
            readClock = do
              remaining <- readIORef readings
              case remaining of
                [] -> pure (Left "clock fixture exhausted")
                value : rest -> writeIORef readings rest >> pure (Right value)
            boundary =
              standardWorkerBoundary
                { createTargetWorkerIntent = \_ _ ->
                    modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
                }
        coordinateWithClock boundary execution readClock
          `shouldReturn` Left (TargetWorkerCoordinatorClockFailed TargetWorkerClockDeadlineReached)
        (_, journal) <- readIORef store
        case (expiryStage, serviceSessionJournalPhase journal) of
          (0, ServiceSessionCreationPrepared _) -> pure ()
          (1, ServiceSessionCreationReserved _) -> pure ()
          (4, _) ->
            serviceSessionJournalDispatchState journal `shouldBe` Just ServiceSessionDispatchIssued
          _ -> expectationFailure "clock refusal did not preserve the expected ownership phase"
        recovered <-
          recoverRetiredTargetWorker execution (const (pure (Right True)))
        recovered `shouldBe` Right (expiryStage == 0)
        observed <- readIORef events
        if expiryStage < 2
          then observed `shouldSatisfy` notElem "job:create"
          else observed `shouldSatisfy` elem "job:create"

    it "retains an issued creation when the clock is asynchronously cancelled" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      readings <- newIORef (0 :: Int)
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          readClock = do
            count <- readIORef readings
            modifyIORef' readings (+ 1)
            if count == 0 then pure (Right admissionTime) else throwIO AsyncCancelled
          boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = \_ _ ->
                  modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      cancelled <- try (coordinateWithClock boundary execution readClock)
      case cancelled of
        Left AsyncCancelled -> pure ()
        Right _ -> expectationFailure "issued-create clock cancellation was swallowed"
      (_, journal) <- readIORef store
      case serviceSessionJournalPhase journal of
        ServiceSessionCreationReserved _ -> pure ()
        _ -> expectationFailure "cancelled issued creation was not retained"
      recoverRetiredTargetWorker execution (const (pure (Right True)))
        `shouldReturn` Right False
      readIORef events `shouldReturn` ["journal:reserved", "journal:creation-issued"]

    it "recovers a prepared reservation after cancellation during Job preparation" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      entered <- newEmptyMVar
      blocked <- newEmptyMVar
      result <- newEmptyMVar
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          boundary = standardWorkerBoundary {prepareTargetWorkerJob = \_ -> putMVar entered () >> takeMVar blocked}
      worker <- forkIO $ do
        outcome <- try (coordinateWithBoundary boundary execution)
        putMVar
          result
          (outcome :: Either AsyncException (Either TargetWorkerCoordinatorError TargetWorkerReceipt))
      takeMVar entered
      throwTo worker ThreadKilled
      takeMVar result `shouldReturn` Left ThreadKilled
      recoverRetiredTargetWorker
        execution
        (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
        `shouldReturn` Right True
      readIORef events `shouldReturn` ["journal:reserved", "journal:vacant"]

    it "refuses a creator whose Job preparation completes after recovery" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      result <- newEmptyMVar
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          prepareLater intent = do
            putMVar entered ()
            takeMVar resume
            pure (prepareTargetSecretWorkerJob "registry/prodbox" 300 intent)
          boundary =
            standardWorkerBoundary
              { prepareTargetWorkerJob = prepareLater
              , createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      _ <- forkIO (coordinateWithBoundary boundary execution >>= putMVar result)
      takeMVar entered
      recoverRetiredTargetWorker
        execution
        (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
        `shouldReturn` Right True
      successor <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
      putMVar resume ()
      outcome <- takeMVar result
      outcome `shouldSatisfy` isLeftValue
      observed <- readIORef events
      observed `shouldSatisfy` notElem "job:create"
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionCreationPrepared successor

    it "prevents a delayed creator after recovery releases its prepared reservation" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      result <- newEmptyMVar
      let underlying = targetSessionRepository store events
          retained =
            targetWorkerRetainedExecutionBoundary
              underlying
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          delayIssue expected next = do
            case serviceSessionJournalPhase next of
              ServiceSessionCreationReserved _ -> putMVar entered () >> takeMVar resume
              _ -> pure ()
            compareAndSwapServiceSessionJournal underlying expected next
          delayedRepository = underlying {compareAndSwapServiceSessionJournal = delayIssue}
          delayed =
            targetWorkerRetainedExecutionBoundary
              delayedRepository
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      _ <- forkIO (coordinateWithBoundary boundary delayed >>= putMVar result)
      takeMVar entered
      recoverRetiredTargetWorker
        retained
        (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
        `shouldReturn` Right True
      successor <- fmap mustRight (reserveTargetWorkerCreation retained workerIntent)
      putMVar resume ()
      outcome <- takeMVar result
      outcome `shouldSatisfy` isLeftValue
      observed <- readIORef events
      observed `shouldSatisfy` notElem "job:create"
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionCreationPrepared successor

    it "retains an issued creation when its CAS reply is lost and never creates" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let underlying = targetSessionRepository store events
          loseIssueReply expected next = do
            written <- compareAndSwapServiceSessionJournal underlying expected next
            pure $ case serviceSessionJournalPhase next of
              ServiceSessionCreationReserved _ -> written >> Left "response lost"
              _ -> written
          lostIssue = underlying {compareAndSwapServiceSessionJournal = loseIssueReply}
          execution =
            targetWorkerRetainedExecutionBoundary
              lostIssue
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      outcome <- coordinateWithBoundary boundary execution
      outcome `shouldSatisfy` isLeftValue
      observed <- readIORef events
      observed `shouldSatisfy` notElem "job:create"
      recoverRetiredTargetWorker
        execution
        (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
        `shouldReturn` Right False
      (_, journal) <- readIORef store
      case serviceSessionJournalPhase journal of
        ServiceSessionCreationReserved _ -> pure ()
        _ -> expectationFailure "issued creation was not retained"

    it "keeps the fence when a prepared-release CAS reply is lost" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let underlying = targetSessionRepository store events
          loseReleaseReply expected next = do
            written <- compareAndSwapServiceSessionJournal underlying expected next
            pure $ case serviceSessionJournalPhase next of
              ServiceSessionVacant _ -> written >> Left "response lost"
              _ -> written
          lostRelease = underlying {compareAndSwapServiceSessionJournal = loseReleaseReply}
          execution repository =
            targetWorkerRetainedExecutionBoundary
              repository
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          ordinary = execution underlying
      original <- fmap mustRight (reserveTargetWorkerCreation ordinary workerIntent)
      recovered <-
        recoverRetiredTargetWorker
          (execution lostRelease)
          (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
      recovered `shouldSatisfy` isLeftValue
      successor <- fmap mustRight (reserveTargetWorkerCreation ordinary workerIntent)
      serviceSessionCreationFence successor `shouldBe` (serviceSessionCreationFence original + 1)
      issued <- issueTargetWorkerCreation ordinary original
      issued `shouldSatisfy` isLeftValue
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionCreationPrepared successor

    it "never invokes create when the reservation CAS response is lost" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let underlying = targetSessionRepository store events
          lostReply =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (written >> Left "response lost")
              }
          execution =
            targetWorkerRetainedExecutionBoundary
              lostReply
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareJournalWriteFailed)
      readIORef events `shouldReturn` ["journal:reserved"]

    it "does not attach when the reserved workload binding CAS response is lost" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      writes <- newIORef (0 :: Int)
      let underlying = targetSessionRepository store events
          lostBindingReply =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  count <- readIORef writes
                  modifyIORef' writes (+ 1)
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (if count == 2 then written >> Left "response lost" else written)
              }
          execution =
            targetWorkerRetainedExecutionBoundary
              lostBindingReply
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ _ ->
                  modifyIORef' events (++ ["worker:attach"])
                    >> pure (Left (TargetWorkerCoordinatorAttachFailed "unexpected"))
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareJournalWriteFailed)
      readIORef events `shouldReturn` ["journal:reserved", "journal:creation-issued", "journal:acquiring"]
      (_, journal) <- readIORef store
      serviceSessionJournalWorkload journal `shouldSatisfy` (/= Nothing)

    it "rejects malformed object UIDs when observing exact workload absence" $ do
      let cases =
            [ ("{\"metadata\":{\"uid\":\"old-uid\"}}", Right False)
            , ("{\"metadata\":{\"uid\":\"new-uid\"}}", Right True)
            , ("{\"metadata\":{\"uid\":\"\"}}", Left "Kubernetes Target worker object UID is invalid")
            , ("{\"metadata\":{\"uid\":\" old-uid \"}}", Left "Kubernetes Target worker object UID is invalid")
            , ("{\"metadata\":{}}", Left "Kubernetes Target worker object response is invalid")
            ]
      forM_ cases $ \(body, expected) ->
        classifyTargetWorkerObjectAbsence "old-uid" body `shouldBe` expected

    it "does not recover an issued but unsettled worker" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
      reservation <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
      issueTargetWorkerCreation execution reservation `shouldReturn` Right ()
      binding <-
        fmap
          mustRight
          (prepareTargetWorkerSessionAttempt execution reservation workerAgentRollout attestation)
      beginTargetWorkerDispatch execution binding `shouldReturn` Right ()
      before <- readIORef events
      recoverRetiredTargetWorker
        execution
        (\_ -> modifyIORef' events (++ ["workload:reobserved"]) >> pure (Right True))
        `shouldReturn` Right False
      readIORef events `shouldReturn` before
      (_, journal) <- readIORef store
      serviceSessionJournalDispatchState journal `shouldBe` Just ServiceSessionDispatchIssued

    it "recovers an unclaimed current retirement after exact independent observation" $ do
      (store, events, execution, _) <- newRetiredTargetSession
      before <- readIORef events
      recovered <- recoverRetiredTargetWorker execution $ \workload -> do
        serviceSessionWorkloadJobUid workload `shouldBe` targetWorkerJobUidText workerJobUid
        serviceSessionWorkloadPodUid workload `shouldBe` targetWorkerPodUidText workerPodUid
        modifyIORef' events (++ ["workload:reobserved"])
        pure (Right True)
      recovered `shouldBe` Right True
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1
      observed <- readIORef events
      drop (length before) observed
        `shouldBe` [ "journal:cleanup-owned"
                   , "workload:reobserved"
                   , "journal:cleanup-required"
                   , "audit:inventory"
                   , "audit:inventory"
                   , "audit:grace"
                   , "audit:inventory"
                   , "journal:cleanup-proven"
                   , "journal:vacant"
                   ]

    it "keeps a claimed retirement occupied when exact re-observation fails" $ do
      (store, events, execution, _) <- newRetiredTargetSession
      before <- readIORef events
      result <- recoverRetiredTargetWorker execution (const (pure (Right False)))
      result `shouldSatisfy` either (const True) (const False)
      observed <- readIORef events
      drop (length before) observed `shouldBe` ["journal:cleanup-owned"]
      (_, journal) <- readIORef store
      case serviceSessionJournalDispatchState journal of
        Just (ServiceSessionDispatchCleanupOwned _) -> pure ()
        _ -> expectationFailure "expected retained recovery owner"

    it "releases durably proven cleanup while the original owner is delayed" $ do
      (store, events, _, binding) <- newRetiredTargetSession
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      result <- newEmptyMVar
      let underlying = targetSessionRepository store events
          delayed =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  case (written, serviceSessionJournalPhase next) of
                    (Right (), ServiceSessionCleanupProven _) -> putMVar entered () >> takeMVar resume
                    _ -> pure ()
                  pure written
              }
          original =
            targetWorkerRetainedExecutionBoundary
              delayed
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          recovery =
            targetWorkerRetainedExecutionBoundary
              underlying
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
      _ <- forkIO (closeTargetWorkerSessionAttempt original binding >>= putMVar result)
      takeMVar entered
      before <- readIORef events
      recoverRetiredTargetWorker
        recovery
        (const (expectationFailure "unexpected workload observation" >> pure (Right True)))
        `shouldReturn` Right True
      after <- readIORef events
      drop (length before) after `shouldBe` ["journal:vacant"]
      successor <- fmap mustRight (reserveTargetWorkerCreation recovery workerIntent)
      putMVar resume ()
      originalResult <- takeMVar result
      originalResult `shouldSatisfy` either (const True) (const False)
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionCreationPrepared successor

    it "admits only one concurrent recovery observer" $ do
      (store, events, execution, _) <- newRetiredTargetSession
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      firstResult <- newEmptyMVar
      observations <- newIORef (0 :: Int)
      let observe _ = do
            modifyIORef' observations (+ 1)
            putMVar entered ()
            takeMVar resume
            pure (Right True)
      _ <- forkIO (recoverRetiredTargetWorker execution observe >>= putMVar firstResult)
      takeMVar entered
      recoverRetiredTargetWorker execution observe `shouldReturn` Right False
      readIORef observations `shouldReturn` 1
      before <- readIORef events
      before `shouldSatisfy` notElem "journal:vacant"
      putMVar resume ()
      takeMVar firstResult `shouldReturn` Right True
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1

    it "prevents the original cleanup from auditing while recovery owns the lane" $ do
      (store, events, execution, binding) <- newRetiredTargetSession
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      result <- newEmptyMVar
      before <- readIORef events
      _ <-
        forkIO
          ( recoverRetiredTargetWorker
              execution
              (\_ -> putMVar entered () >> takeMVar resume >> pure (Right True))
              >>= putMVar result
          )
      takeMVar entered
      rejected <- closeTargetWorkerSessionAttempt execution binding
      rejected `shouldSatisfy` either (const True) (const False)
      observed <- readIORef events
      drop (length before) observed `shouldBe` ["journal:cleanup-owned"]
      putMVar resume ()
      takeMVar result `shouldReturn` Right True
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1

    it "does not re-observe or audit after a lost recovery-claim reply" $ do
      (store, events, _, _) <- newRetiredTargetSession
      let underlying = targetSessionRepository store events
          lostClaim =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (written >> Left "response lost")
              }
          execution =
            targetWorkerRetainedExecutionBoundary
              lostClaim
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
      before <- readIORef events
      result <- recoverRetiredTargetWorker execution $ \_ ->
        modifyIORef' events (++ ["workload:reobserved"]) >> pure (Right True)
      result `shouldSatisfy` either (const True) (const False)
      observed <- readIORef events
      drop (length before) observed `shouldBe` ["journal:cleanup-owned"]
      (_, journal) <- readIORef store
      case serviceSessionJournalDispatchState journal of
        Just (ServiceSessionDispatchCleanupOwned _) -> pure ()
        _ -> expectationFailure "expected retained recovery owner"

    it "retains the recovery claim on cancellation during re-observation" $ do
      (store, events, execution, _) <- newRetiredTargetSession
      entered <- newEmptyMVar
      blocked <- newEmptyMVar
      result <- newEmptyMVar
      before <- readIORef events
      worker <- forkIO $ do
        outcome <- try (recoverRetiredTargetWorker execution (\_ -> putMVar entered () >> takeMVar blocked))
        putMVar result (outcome :: Either AsyncException (Either Text Bool))
      takeMVar entered
      throwTo worker ThreadKilled
      takeMVar result `shouldReturn` Left ThreadKilled
      observed <- readIORef events
      drop (length before) observed `shouldBe` ["journal:cleanup-owned"]
      (_, journal) <- readIORef store
      case serviceSessionJournalDispatchState journal of
        Just (ServiceSessionDispatchCleanupOwned _) -> pure ()
        _ -> expectationFailure "expected retained recovery owner"

    it "retains the recovery claim on cancellation during accessor audit" $ do
      (store, events, _, _) <- newRetiredTargetSession
      entered <- newEmptyMVar
      blocked <- newEmptyMVar
      result <- newEmptyMVar
      let audit =
            (orderedTargetAuditOps events)
              { auditListAccessors = putMVar entered () >> takeMVar blocked
              }
          execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              audit
              unusedTargetIntentAuthorityClient
      worker <- forkIO $ do
        outcome <- try (recoverRetiredTargetWorker execution (const (pure (Right True))))
        putMVar result (outcome :: Either AsyncException (Either Text Bool))
      takeMVar entered
      throwTo worker ThreadKilled
      takeMVar result `shouldReturn` Left ThreadKilled
      (_, journal) <- readIORef store
      case (serviceSessionJournalDispatchState journal, serviceSessionJournalPhase journal) of
        (Just (ServiceSessionDispatchCleanupOwned _), ServiceSessionCleanupRequired _ _) -> pure ()
        _ -> expectationFailure "expected retained owner and cleanup-required phase"
      observed <- readIORef events
      observed `shouldSatisfy` notElem "journal:vacant"

    it "requires a fresh invocation after recovering a retired predecessor" $ do
      (store, events, retained, _) <- newRetiredTargetSession
      let execution =
            retained {authorizeTargetWorkerExecution = authorizeTargetWorkerExecution workerExecutionBoundary}
          boundary =
            standardWorkerBoundary
              { observeRetiredTargetWorkerAbsent = \_ -> modifyIORef' events (++ ["workload:reobserved"]) >> pure (Right True)
              , createTargetWorkerIntent = \_ _ -> modifyIORef' events (++ ["job:create"]) >> pure (Right workerJobUid)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left
          (TargetWorkerCoordinatorSessionPrepareFailed TargetWorkerSessionPrepareRecoveryCompletedRetryRequired)
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1
      observed <- readIORef events
      observed `shouldSatisfy` elem "workload:reobserved"
      observed `shouldSatisfy` elem "journal:vacant"
      observed `shouldSatisfy` notElem "job:create"

    it "admits only one cleanup caller for a retired workload" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      entered <- newEmptyMVar
      resume <- newEmptyMVar
      firstResult <- newEmptyMVar
      auditCount <- newIORef (0 :: Int)
      let repository = targetSessionRepository store events
          ordinaryAudit = orderedTargetAuditOps events
          setup = targetWorkerRetainedExecutionBoundary repository ordinaryAudit unusedTargetIntentAuthorityClient
          blockingAudit =
            ordinaryAudit
              { auditListAccessors = do
                  count <- readIORef auditCount
                  modifyIORef' auditCount (+ 1)
                  if count == 0 then putMVar entered () >> takeMVar resume else pure ()
                  auditListAccessors ordinaryAudit
              }
          execution = targetWorkerRetainedExecutionBoundary repository blockingAudit unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
      reservation <- fmap mustRight (reserveTargetWorkerCreation setup workerIntent)
      issueTargetWorkerCreation setup reservation `shouldReturn` Right ()
      binding <-
        fmap mustRight (prepareTargetWorkerSessionAttempt setup reservation workerAgentRollout attestation)
      recordTargetWorkerRetirement setup attestation binding `shouldReturn` Right ()
      _ <- forkIO (closeTargetWorkerSessionAttempt execution binding >>= putMVar firstResult)
      takeMVar entered
      rejected <- closeTargetWorkerSessionAttempt execution binding
      rejected `shouldSatisfy` either (const True) (const False)
      readIORef auditCount `shouldReturn` 1
      putMVar resume ()
      takeMVar firstResult `shouldReturn` Right ()
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1

    it "does not audit or release after a lost cleanup-claim response" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      writes <- newIORef (0 :: Int)
      let underlying = targetSessionRepository store events
          lostClaim =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  count <- readIORef writes
                  modifyIORef' writes (+ 1)
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (if count == 6 then written >> Left "response lost" else written)
              }
          execution =
            targetWorkerRetainedExecutionBoundary
              lostClaim
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
      reservation <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
      issueTargetWorkerCreation execution reservation `shouldReturn` Right ()
      binding <-
        fmap
          mustRight
          (prepareTargetWorkerSessionAttempt execution reservation workerAgentRollout attestation)
      recordTargetWorkerRetirement execution attestation binding `shouldReturn` Right ()
      before <- readIORef events
      rejected <- closeTargetWorkerSessionAttempt execution binding
      rejected `shouldSatisfy` either (const True) (const False)
      after <- readIORef events
      after `shouldBe` (before ++ ["journal:cleanup-owned"])
      (_, journal) <- readIORef store
      case serviceSessionJournalDispatchState journal of
        Just (ServiceSessionDispatchCleanupOwned _) -> pure ()
        _ -> expectationFailure "expected retained cleanup owner"

    it "keeps the lane occupied when the retirement CAS response is lost" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      writes <- newIORef (0 :: Int)
      let underlying = targetSessionRepository store events
          lostRetirementReply =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  count <- readIORef writes
                  modifyIORef' writes (+ 1)
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (if count == 5 then written >> Left "response lost" else written)
              }
          retained =
            targetWorkerRetainedExecutionBoundary
              lostRetirementReply
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution = retained {authorizeTargetWorkerExecution = \_ _ _ _ -> pure (Left "unavailable")}
      result <- coordinateWithBoundary standardWorkerBoundary execution
      case result of
        Left (TargetWorkerCoordinatorSessionCleanupFailed _) -> pure ()
        _ -> expectationFailure "expected retirement journal failure"
      (_, journal) <- readIORef store
      serviceSessionJournalDispatchState journal `shouldBe` Just ServiceSessionWorkloadRetired
      observed <- readIORef events
      observed `shouldSatisfy` elem "journal:workload-retired"
      observed `shouldSatisfy` notElem "journal:vacant"
      reserveTargetWorkerCreation retained workerIntent
        `shouldReturn` Left TargetWorkerSessionPrepareRoleOccupied

    it "does not attach or release the lane when dispatch CAS response is lost" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      writes <- newIORef (0 :: Int)
      let underlying = targetSessionRepository store events
          lostDispatchReply =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  count <- readIORef writes
                  modifyIORef' writes (+ 1)
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (if count == 5 then written >> Left "response lost" else written)
              }
          retained =
            targetWorkerRetainedExecutionBoundary
              lostDispatchReply
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution =
            retained {authorizeTargetWorkerExecution = authorizeTargetWorkerExecution workerExecutionBoundary}
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ _ ->
                  modifyIORef' events (++ ["worker:attach"])
                    >> pure (Left (TargetWorkerCoordinatorAttachFailed "unexpected"))
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorAttachFailed "worker dispatch journal unavailable")
      (_, journal) <- readIORef store
      serviceSessionJournalDispatchState journal `shouldBe` Just ServiceSessionDispatchIssued
      observed <- readIORef events
      observed `shouldSatisfy` notElem "worker:attach"
      observed `shouldSatisfy` notElem "journal:vacant"

    it "does not authorize dispatch from a lost acquisition CAS reply" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let underlying = targetSessionRepository store events
          lostReply =
            underlying
              { compareAndSwapServiceSessionJournal = \expected next -> do
                  written <- compareAndSwapServiceSessionJournal underlying expected next
                  pure (written >> Left "response lost")
              }
          execution =
            targetWorkerRetainedExecutionBoundary
              lostReply
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
      reserveTargetWorkerCreation execution workerIntent
        `shouldReturn` Left TargetWorkerSessionPrepareJournalWriteFailed
      (_, retainedJournal) <- readIORef store
      serviceSessionJournalPhase retainedJournal
        `shouldBe` ServiceSessionCreationPrepared
          ( mustRight
              ( mkServiceSessionCreationReservation
                  (targetWorkerSessionOperationId workerIntent)
                  (targetWorkerIntentJobName workerIntent)
                  1
              )
          )
      serviceSessionJournalWorkload retainedJournal `shouldBe` Nothing
      readIORef events `shouldReturn` ["journal:reserved"]
      reserveTargetWorkerCreation execution workerIntent
        `shouldReturn` Left TargetWorkerSessionPrepareRoleOccupied
      readIORef events `shouldReturn` ["journal:reserved"]

    it "durably activates the exact server accessor before authorizing worker cleanup" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
      reservation <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
      issueTargetWorkerCreation execution reservation `shouldReturn` Right ()
      prepared <-
        prepareTargetWorkerSessionAttempt
          execution
          reservation
          workerAgentRollout
          attestation
      binding <- case prepared of
        Left cause -> expectationFailure (show cause) >> pure (workerSessionBinding attestation)
        Right value -> pure value
      (_, boundJournal) <- readIORef store
      decodeServiceSessionJournal (encodeServiceSessionJournal boundJournal) `shouldBe` Right boundJournal
      case serviceSessionJournalWorkloadEvidence boundJournal of
        Nothing -> expectationFailure "expected the complete attempt evidence"
        Just evidence -> do
          let attempt = serviceSessionWorkloadEvidenceAttempt evidence
              workload = serviceSessionWorkloadEvidenceWorkload evidence
              alteredAttempt = attempt {wireAttemptDeploymentUid = "other-deployment-uid"}
              alteredEvidence = mustRight (mkServiceSessionWorkloadEvidence workload alteredAttempt)
              initial = mustRight (mkInitialServiceSessionJournal targetSecretWorkerVaultRole)
          stepServiceSessionJournal (BeginServiceSessionVerifiedWorkload binding alteredEvidence) initial
            `shouldBe` Left ServiceSessionJournalInvariantInvalid
          let oldV3 =
                mustRight (stepServiceSessionJournal (BeginServiceSessionVerifiedWorkload binding evidence) initial)
          decodeServiceSessionJournal (encodeServiceSessionJournal oldV3) `shouldBe` Right oldV3
          let reserved = mustRight (stepServiceSessionJournal (ReserveServiceSessionCreation reservation) initial)
              creationIssued = mustRight (stepServiceSessionJournal (IssueServiceSessionCreation reservation) reserved)
              bound =
                mustRight
                  (stepServiceSessionJournal (BindServiceSessionCreation reservation binding evidence) creationIssued)
              otherReservation =
                mustRight
                  ( mkServiceSessionCreationReservation
                      (targetWorkerSessionOperationId workerIntent)
                      (targetWorkerIntentJobName workerIntent)
                      2
                  )
          decodeServiceSessionJournal (encodeServiceSessionJournal reserved) `shouldBe` Right reserved
          decodeServiceSessionJournal (encodeServiceSessionJournal bound) `shouldBe` Right bound
          stepServiceSessionJournal (BindServiceSessionCreation reservation binding evidence) reserved
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (BindServiceSessionCreation otherReservation binding evidence) reserved
            `shouldBe` Left ServiceSessionJournalInvariantInvalid
          stepServiceSessionJournal (BindServiceSessionCreation reservation binding alteredEvidence) reserved
            `shouldBe` Left ServiceSessionJournalInvariantInvalid
          stepServiceSessionJournal (ReserveServiceSessionCreation reservation) reserved
            `shouldBe` Left ServiceSessionTransitionConflict
          let precleaned = mustRight (stepServiceSessionJournal (CommitServiceSessionPrecleaned binding) bound)
              ready = mustRight (stepServiceSessionJournal (CommitServiceSessionLoginAttempt binding) precleaned)
              issued = mustRight (stepServiceSessionJournal (BeginServiceSessionDispatch binding) ready)
              retiredReady = mustRight (stepServiceSessionJournal (RetireServiceSessionWorkload binding workload) ready)
              owner = mustRight (mkOwnerNonce "cleanup-owner")
              otherOwner = mustRight (mkOwnerNonce "other-owner")
              claimedForCleanup = mustRight (stepServiceSessionJournal (ClaimServiceSessionCleanup binding owner) retiredReady)
          serviceSessionJournalDispatchState issued `shouldBe` Just ServiceSessionDispatchIssued
          stepServiceSessionJournal (RequireServiceSessionCleanup binding) issued
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (RequireServiceSessionCleanup binding) ready
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (RetireServiceSessionWorkload binding workload) issued
            `shouldBe` Left ServiceSessionTransitionConflict
          let wrongWorkload =
                mustRight
                  ( mkServiceSessionWorkload
                      (serviceSessionWorkloadJobName workload)
                      "different-job-uid"
                      (serviceSessionWorkloadPodName workload)
                      (serviceSessionWorkloadPodUid workload)
                      (serviceSessionWorkloadServiceAccountUid workload)
                  )
          stepServiceSessionJournal (RetireServiceSessionWorkload binding wrongWorkload) ready
            `shouldBe` Left ServiceSessionJournalInvariantInvalid
          stepServiceSessionJournal (BeginServiceSessionDispatch binding) claimedForCleanup
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (RequireServiceSessionCleanup binding) claimedForCleanup
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (ClaimServiceSessionCleanup binding otherOwner) claimedForCleanup
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (RequireOwnedServiceSessionCleanup binding otherOwner) claimedForCleanup
            `shouldBe` Left ServiceSessionTransitionConflict
          stepServiceSessionJournal (SettleServiceSessionDispatch binding) issued
            `shouldBe` Left ServiceSessionTransitionConflict
          let retired = mustRight (stepServiceSessionJournal (RetireServiceSessionWorkload binding workload) bound)
              claimed = mustRight (stepServiceSessionJournal (ClaimServiceSessionCleanup binding owner) retired)
              required = mustRight (stepServiceSessionJournal (RequireOwnedServiceSessionCleanup binding owner) claimed)
              proven = mustRight (stepServiceSessionJournal (ProveOwnedServiceSessionCleanup binding owner) required)
              released = mustRight (stepServiceSessionJournal (ReleaseOwnedServiceSession binding owner) proven)
          decodeServiceSessionJournal (encodeServiceSessionJournal released) `shouldBe` Right released
          stepServiceSessionJournal (BeginServiceSessionVerifiedWorkload binding evidence) released
            `shouldBe` Left ServiceSessionJournalInvariantInvalid
          mkServiceSessionWorkloadEvidence workload (attempt {wireAttemptPodUid = "other-pod-uid"})
            `shouldBe` Left ServiceSessionJournalInvariantInvalid
      case serviceSessionJournalWorkload boundJournal of
        Nothing -> expectationFailure "expected the exact retained Target workload"
        Just workload -> do
          serviceSessionWorkloadJobName workload `shouldBe` targetWorkerIntentJobName workerIntent
          serviceSessionWorkloadJobUid workload `shouldBe` targetWorkerJobUidText workerJobUid
          serviceSessionWorkloadPodName workload `shouldBe` "target-secret-worker-pod"
          serviceSessionWorkloadPodUid workload `shouldBe` targetWorkerPodUidText workerPodUid
          serviceSessionWorkloadServiceAccountUid workload
            `shouldBe` targetWorkerServiceAccountUidText workerServiceAccountUid
      readIORef events
        `shouldReturn` [ "journal:reserved"
                       , "journal:creation-issued"
                       , "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       ]
      beginTargetWorkerDispatch execution binding `shouldReturn` Right ()
      beforeUnsafeClose <- readIORef events
      refusedClose <- closeTargetWorkerSessionAttempt execution binding
      refusedClose `shouldSatisfy` either (const True) (const False)
      readIORef events `shouldReturn` beforeUnsafeClose
      activateTargetWorkerSessionAttempt
        execution
        attestation
        binding
        "worker-accessor"
        `shouldReturn` Right ()
      readIORef events
        `shouldReturn` [ "journal:reserved"
                       , "journal:creation-issued"
                       , "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "journal:dispatch-issued"
                       , "audit:lookup"
                       , "journal:active"
                       ]
      settleTargetWorkerDispatch execution binding `shouldReturn` Right ()
      recordTargetWorkerRetirement execution attestation binding `shouldReturn` Right ()
      closeTargetWorkerSessionAttempt execution binding `shouldReturn` Right ()
      readIORef events
        `shouldReturn` [ "journal:reserved"
                       , "journal:creation-issued"
                       , "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "journal:dispatch-issued"
                       , "audit:lookup"
                       , "journal:active"
                       , "journal:dispatch-settled"
                       , "journal:workload-retired"
                       , "journal:cleanup-owned"
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
        `shouldReturn` [ "journal:reserved"
                       , "journal:creation-issued"
                       , "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "journal:dispatch-issued"
                       , "worker:provisional"
                       , "audit:lookup"
                       , "journal:active"
                       , "worker:cleanup-authorized"
                       , "worker:cleanup-complete"
                       , "journal:dispatch-settled"
                       , "journal:workload-retired"
                       , "journal:cleanup-owned"
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

    it "settles and closes an acknowledged worker refusal" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let retained =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution =
            retained {authorizeTargetWorkerExecution = authorizeTargetWorkerExecution workerExecutionBoundary}
          completion = mustRight (refusedTargetWorkerProvisionalCompletion "worker-accessor" "worker-refused")
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ decide -> decide (encodeTargetWorkerProvisionalCompletion completion)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left (TargetWorkerCoordinatorMaterializationRefused "worker-refused")
      (_, journal) <- readIORef store
      serviceSessionJournalPhase journal `shouldBe` ServiceSessionVacant 1
      observed <- readIORef events
      observed `shouldSatisfy` elem "journal:dispatch-settled"
      observed `shouldSatisfy` elem "journal:vacant"

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
              { createTargetWorkerIntent = \_ _ -> pure (Left "create response lost")
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

    it "preserves an unowned Job when Pod observation fails or returns a foreign Job UID" $ do
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
          readIORef deleted `shouldReturn` []

    it "preserves an unowned workload when attestation refuses" $ do
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
      readIORef deleted `shouldReturn` []

    it "retains the session and deletes the exact Job/Pod after attach cancellation" $ do
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
      readIORef closed `shouldReturn` 0
      readIORef deleted `shouldReturn` 1
      readIORef absent `shouldReturn` 1

    it "prepares a production Job using only the deployment read" testProductionJobPreparation

    it "binds a prepared Job to its exact worker intent" $ do
      let prepared = mustRight (prepareTargetSecretWorkerJob "registry/prodbox" 300 workerIntent)
          expected =
            LazyByteString.toStrict
              (Aeson.encode (mustRight (renderTargetSecretWorkerJob "registry/prodbox" 300 workerIntent)))
      targetWorkerPreparedJobBytes workerIntent prepared `shouldBe` Right expected
      targetWorkerPreparedJobBytes tlsWorkerIntent prepared
        `shouldBe` Left "Target worker prepared Job binding mismatch"

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

testProductionJobPreparation :: IO ()
testProductionJobPreparation = do
  childRoot <- lookupEnv "TARGET_WORKER_PREPARE_FIXTURE"
  maybe
    (withSystemTempDirectory "prodbox-target-job-prepare" runPreparationParent)
    runPreparationChild
    childRoot

runPreparationParent :: FilePath -> IO ()
runPreparationParent root = do
  let executable = root </> "kubectl"
      trace = root </> "trace"
  writeFile
    executable
    ( unlines
        [ "#!/bin/sh"
        , "printf '%s\\n' \"$*\" >> \"$PREPARE_TRACE\""
        , "printf '%s' '{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"target-secret-agent\",\"image\":\"registry/prodbox:stable\"}]}}}}'"
        ]
    )
  setFileMode
    executable
    (ownerReadMode `unionFileModes` ownerWriteMode `unionFileModes` ownerExecuteMode)
  testExecutable <- getExecutablePath
  let child =
        (Process.proc testExecutable ["-p", "prepares a production Job using only the deployment read"])
          { Process.env = Just [("PATH", root), ("TARGET_WORKER_PREPARE_FIXTURE", root)]
          }
  (exitCode, _, stderrText) <- Process.readCreateProcessWithExitCode child ""
  unless
    (exitCode == ExitSuccess)
    (expectationFailure ("isolated preparation test failed: " <> stderrText))
  readFile trace
    `shouldReturn` "--namespace target-secret-agent get deployment/target-secret-agent --output=json\n"

runPreparationChild :: FilePath -> IO ()
runPreparationChild root = do
  let trace = root </> "trace"
      connection =
        TargetWorkerJobConnection
          { targetWorkerJobEnvironment = Just [("PATH", root), ("PREPARE_TRACE", trace)]
          , targetWorkerJobWorkingDirectory = root
          , targetWorkerJobImageRepository = "registry/prodbox"
          , targetWorkerJobMaximumRuntimeSeconds = 300
          }
  prepared <- prepareTargetWorkerJob (targetWorkerKubernetesBoundary connection) workerIntent
  let bytes = mustRight (targetWorkerPreparedJobBytes workerIntent (mustRight prepared))
  ByteString.isInfixOf "registry/prodbox:stable" bytes `shouldBe` True

standardWorkerBoundary :: TargetWorkerKubernetesBoundary IO
standardWorkerBoundary =
  TargetWorkerKubernetesBoundary
    { observeSelectedTargetAgentRollout = pure (Right workerAgentRollout)
    , prepareTargetWorkerJob = \intent -> pure (prepareTargetSecretWorkerJob "registry/prodbox" 300 intent)
    , createTargetWorkerIntent = \_ _ -> pure (Right workerJobUid)
    , recoverTargetWorkerIntent =
        const (pure (Right (TargetWorkerCreateRecovered workerJobUid)))
    , observeTargetWorkerIntent =
        \intent -> pure (Right (Just (rawWorkerObservation intent)))
    , attachTargetWorkerIngress =
        \_ _ _ -> pure (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
    , observeRetiredTargetWorkerAbsent = const (pure (Right True))
    , deleteTargetWorkerIntent = \_ _ _ -> pure (Right ())
    , observeTargetWorkerIntentAbsent = \_ _ _ -> pure (Right True)
    }

coordinateWithBoundary
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateWithBoundary boundary execution =
  coordinateWithClock boundary execution (pure (Right admissionTime))

coordinateWithClock
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> IO (Either Text AuthorityTime)
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateWithClock boundary execution readTime =
  coordinateDirectTargetMaterialization
    boundary
    execution
    acceptedAuthority
    admissionTime
    readTime
    workerAgentIdentity
    workerTarget
    TargetWorkerDirectAws
    workerImageDigest
    signedIntentBytes
    workerPayload

newRetiredTargetSession
  :: IO (TargetSessionStore, IORef [Text], TargetWorkerExecutionBoundary IO, ServiceSessionBinding)
newRetiredTargetSession = do
  store <- newTargetSessionStore
  events <- newIORef ([] :: [Text])
  let execution =
        targetWorkerRetainedExecutionBoundary
          (targetSessionRepository store events)
          (orderedTargetAuditOps events)
          unusedTargetIntentAuthorityClient
      attestation = workerAttestation workerIntent
  reservation <- fmap mustRight (reserveTargetWorkerCreation execution workerIntent)
  issueTargetWorkerCreation execution reservation `shouldReturn` Right ()
  binding <-
    fmap
      mustRight
      (prepareTargetWorkerSessionAttempt execution reservation workerAgentRollout attestation)
  recordTargetWorkerRetirement execution attestation binding `shouldReturn` Right ()
  pure (store, events, execution, binding)

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
        (revision, previous) <- readIORef store
        if revision /= expected
          then pure (Left "fixture CAS conflict")
          else do
            writeIORef store (revision + 1, next)
            modifyIORef'
              events
              (++ ["journal:" <> targetSessionTransitionToken previous next])
            pure (Right ())
    }

targetSessionTransitionToken :: ServiceSessionJournal -> ServiceSessionJournal -> Text
targetSessionTransitionToken previous next =
  case (serviceSessionJournalDispatchState previous, serviceSessionJournalDispatchState next) of
    (Just ServiceSessionDispatchReady, Just ServiceSessionDispatchIssued) -> "dispatch-issued"
    (Just ServiceSessionDispatchIssued, Just ServiceSessionDispatchSettled) -> "dispatch-settled"
    (Just ServiceSessionDispatchSettled, Just ServiceSessionWorkloadRetired) -> "workload-retired"
    (Just ServiceSessionDispatchReady, Just ServiceSessionWorkloadRetired) -> "workload-retired"
    (Just ServiceSessionWorkloadRetired, Just (ServiceSessionDispatchCleanupOwned _)) -> "cleanup-owned"
    _ -> targetSessionPhaseToken (serviceSessionJournalPhase next)

targetSessionPhaseToken :: ServiceSessionPhase -> Text
targetSessionPhaseToken phase = case phase of
  ServiceSessionVacant _ -> "vacant"
  ServiceSessionAcquiring _ -> "acquiring"
  ServiceSessionPrecleaned _ -> "precleaned"
  ServiceSessionLoginAttemptCommitted _ -> "login-attempt-committed"
  ServiceSessionActive _ _ -> "active"
  ServiceSessionCleanupRequired _ _ -> "cleanup-required"
  ServiceSessionCleanupProven _ -> "cleanup-proven"
  ServiceSessionWorkloadOwned inner _ -> targetSessionPhaseToken inner
  ServiceSessionVerifiedWorkloadOwned inner _ -> targetSessionPhaseToken inner
  ServiceSessionCreationReserved _ -> "creation-issued"
  ServiceSessionCreationPrepared _ -> "reserved"
  ServiceSessionDispatchOwned inner _ _ -> targetSessionPhaseToken inner

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
    { reserveTargetWorkerCreation = \intent ->
        pure
          ( Right
              ( mustRight
                  ( mkServiceSessionCreationReservation
                      (targetWorkerSessionOperationId intent)
                      (targetWorkerIntentJobName intent)
                      1
                  )
              )
          )
    , recoverRetiredTargetWorker = const (pure (Right False))
    , issueTargetWorkerCreation = const (pure (Right ()))
    , prepareTargetWorkerSessionAttempt =
        \_ _ attestation -> pure (Right (workerSessionBinding attestation))
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
    , beginTargetWorkerDispatch = const (pure (Right ()))
    , settleTargetWorkerDispatch = const (pure (Right ()))
    , activateTargetWorkerSessionAttempt = \_ _ _ -> pure (Right ())
    , recordTargetWorkerRetirement = \_ _ -> pure (Right ())
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
