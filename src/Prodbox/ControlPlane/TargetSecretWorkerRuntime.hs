{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Production runtime for the one-shot Target Secret Agent materializer.
--
-- The worker reads one bounded stdin frame, binds it to its Downward-API Pod
-- identity and immutable Job arguments, acquires a fresh worker-only Vault
-- Kubernetes session, verifies the Authority trust record and signed intent,
-- performs the exact registered KV-v2 generation CAS/readbacks, emits only an
-- opaque receipt, and revokes the session on every terminal path.
module Prodbox.ControlPlane.TargetSecretWorkerRuntime
  ( TargetSecretWorkerOptions (..)
  , TargetWorkerRewrapBoundary (..)
  , retainedTargetWorkerRewrapBoundary
  , TargetSecretWorkerRuntimeError (..)
  , renderTargetSecretWorkerRuntimeRefusal
  , targetSecretWorkerTlsHomeRewrapRefusalTokens
  , targetSecretWorkerTlsApplyRefusalTokens
  , classifyTlsHomeRewrapWorkerResult
  , targetSecretWorkerCommitmentKey
  , targetSecretWorkerTrustPath
  , readTargetWorkerPodUid
  , readTargetWorkerPodName
  , readTargetWorkerProjectedToken
  , decodeTargetWorkerAcceptedAuthority
  , authenticateTargetWorkerFrame
  , guardTargetWorkerAuditInventory
  , targetWorkerServiceLoginAccepted
  , TargetWorkerAuditorRecoveryBoundary (..)
  , acquireTargetWorkerAuditorWith
  , runTargetSecretWorker
  , runTargetSecretWorkerWithRewrap
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( AsyncException
  , IOException
  , SomeException
  , bracket
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as ByteStringBuilder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.Cluster.FederationRegistration
  ( ChildCustodyExport (childCustodyExportReceipt)
  , FederationRegistrationIntent (federationRegistrationExport)
  , federationRegistrationTargetAgent
  , validateFederationRegistrationIntent
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( targetSecretWorkerAuditorVaultRole
  , targetSecretWorkerVaultRole
  )
import Prodbox.ControlPlane.BootstrapCustodyEndpoint
  ( TargetChildCustodyRepository (..)
  , vaultTargetChildCustodyRepository
  )
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( openRetainedDestinationOpeningForGeneration
  )
import Prodbox.ControlPlane.RoleReadiness (noRoleReadinessContribution)
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , ServiceSessionDispatchState (ServiceSessionDispatchIssued)
  , ServiceSessionJournalRepository (readServiceSessionJournal)
  , ServiceSessionJournalSnapshot (..)
  , ServiceSessionPhase (ServiceSessionActive, ServiceSessionLoginAttemptCommitted)
  , serviceSessionBindingFence
  , serviceSessionJournalDispatchState
  , serviceSessionJournalPhase
  )
import Prodbox.ControlPlane.TargetAuthorityEpoch (targetEpochWorkerAuthority)
import Prodbox.ControlPlane.TargetAuthorityEpochCodec (decodeTargetAuthorityEpochFields)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , TargetSecretPayload
  , compiledTargetSecretSink
  , targetSecretIdToken
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentIdentity
  , targetAgentIdentityText
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( RawTargetWorkerPodObservation (..)
  , TargetWorkerAttestation
  , TargetWorkerDataObservation (..)
  , TargetWorkerExecutionError (..)
  , TargetWorkerImageDigest
  , TargetWorkerIngressSchema (..)
  , TargetWorkerIntent
  , TargetWorkerJobUid
  , TargetWorkerMaterializationResult (..)
  , TargetWorkerMetadataObservation (..)
  , TargetWorkerOperationResult (..)
  , TargetWorkerPodUid
  , TargetWorkerProvisionalCompletion
  , TargetWorkerReceipt
  , TargetWorkerServiceAccountUid
  , TargetWorkerVaultBoundary (..)
  , attestTargetWorkerPod
  , encodeTargetWorkerProvisionalCompletion
  , executeTargetWorkerMaterialization
  , mkTargetWorkerPodUid
  , prepareTargetWorkerIntent
  , refusedTargetWorkerProvisionalCompletion
  , successfulTargetWorkerOperationProvisionalCompletion
  , targetWorkerAttestedIntent
  , targetWorkerCleanupAuthorization
  , targetWorkerCleanupCompletion
  , targetWorkerImageDigestText
  , targetWorkerIntentAgentIdentity
  , targetWorkerIntentDeadline
  , targetWorkerIntentGeneration
  , targetWorkerIntentImageDigest
  , targetWorkerIntentJobName
  , targetWorkerIntentRequestDigest
  , targetWorkerIntentSchema
  , targetWorkerIntentServiceAccount
  , targetWorkerIntentTarget
  , targetWorkerJobUidText
  , targetWorkerKubernetesUidMaximumCharacters
  , targetWorkerPodUidText
  , targetWorkerProvisionalCompletionMaximumBytes
  , targetWorkerSchemaToken
  , targetWorkerServiceAccountUidText
  )
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
  ( TargetWorkerFrameBinding
  , TargetWorkerIngressError
  , TargetWorkerOperationInput (..)
  , targetWorkerFrameDeadline
  , targetWorkerFrameExecutionPermit
  , targetWorkerFrameImageDigest
  , targetWorkerFrameJobName
  , targetWorkerFrameJobUid
  , targetWorkerFramePodName
  , targetWorkerFramePodUid
  , targetWorkerFrameRequestDigest
  , targetWorkerFrameSchema
  , targetWorkerFrameServiceAccount
  , targetWorkerFrameServiceAccountUid
  , targetWorkerFrameSessionFence
  , targetWorkerFrameSignedIntent
  , targetWorkerFrameTarget
  , targetWorkerIngressMaximumBytes
  , withTargetWorkerOperationIngress
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( TargetWorkerExecutionPermitError
  , verifiedPermitImageDigest
  , verifiedPermitJobName
  , verifiedPermitJobUid
  , verifiedPermitPodName
  , verifiedPermitPodUid
  , verifiedPermitRequestDigest
  , verifiedPermitServiceAccount
  , verifiedPermitServiceAccountUid
  , verifiedPermitSessionBinding
  , verifyTargetWorkerExecutionPermit
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekExchangeError (..)
  , TlsDekTransitFailure (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsHomeRewrapRequest (..)
  , TlsHomeRewrapResult (..)
  , TlsHomeWrapRequest (..)
  , TlsHomeWrapResult (..)
  , TlsSecretApplyFailure (..)
  , TlsTargetAgentError (..)
  , TlsTargetPrepareResult (..)
  , TlsTargetRestoreRequest (..)
  , TlsTargetRestoreResult (..)
  , TlsTargetRetainRequest (..)
  , TlsTargetRetainResult (..)
  , TlsTargetVerifyRequest (..)
  , TlsTargetVerifyResult (..)
  , prepareTlsTargetExchange
  , restoreTlsAtSelectedAgent
  , retainTlsAtSelectedAgent
  , rewrapTlsDekAtHomeAgent
  , verifyTlsSourceAtSelectedAgent
  , wrapTlsDekAtHomeAgent
  )
import Prodbox.ControlPlane.TlsTargetAgentProduction
  ( tlsDekVaultBoundary
  , tlsTargetAgentProductionBoundaries
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , classifyVaultAccessorLookupResponse
  , isBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  )
import Prodbox.ControlPlane.VaultServiceSessionJournal (vaultServiceSessionJournalRepository)
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( SRetainedMaterialSchema (SRetainedAcmeEabMaterial, SRetainedSesSmtpMaterial)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2SecretMetadata (..)
  , KvV2VersionedSecret (..)
  , TokenAccessorListing (..)
  , VaultAddress (..)
  , VaultCasOutcome (..)
  , VaultKubernetesLoginResult (..)
  , classifyVaultCasOutcome
  , renderVaultCasOutcome
  , vaultKubernetesLoginWithLease
  , vaultKvCasWriteV2
  , vaultKvReadMetadataV2
  , vaultKvReadV2
  , vaultKvReadVersionedV2
  , vaultKvWriteCustomMetadataV2
  , vaultListTokenAccessors
  , vaultLookupTokenAccessorInfo
  , vaultRevokeSelf
  , vaultRevokeTokenAccessor
  , vaultTokenAccessorAbsent
  , vaultTransitHmacSha256
  )
import Prodbox.Vault.Session
  ( LoginLease (..)
  , VaultSession
  , newVaultSession
  , realSessionClock
  , sessionAddress
  , sessionToken
  , withSessionToken
  )
import System.Exit (ExitCode (..))
import System.IO (Handle, hFlush, stdin, stdout)
import System.IO.Error (isEOFError)
import System.Posix.Files (fileSize, getFdStatus, isRegularFile)
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Types (Fd)

data TargetSecretWorkerOptions = TargetSecretWorkerOptions
  { targetSecretWorkerExpectedTarget :: !TargetSecretId
  , targetSecretWorkerExpectedAgentIdentity :: !TargetAgentIdentity
  , targetSecretWorkerExpectedSchema :: !TargetWorkerIngressSchema
  , targetSecretWorkerExpectedImageDigest :: !TargetWorkerImageDigest
  , targetSecretWorkerExpectedRequestDigest :: !TargetValueDigest
  , targetSecretWorkerExpectedDeadline :: !AuthorityTime
  , targetSecretWorkerPodUidFile :: !FilePath
  , targetSecretWorkerPodNameFile :: !FilePath
  , targetSecretWorkerServiceAccountTokenFile :: !FilePath
  }
  deriving stock (Eq, Show)

-- | Exact retained-material input seam.  No arbitrary target/path callback is
-- representable.  The default production worker supports direct AWS targets
-- and opens the two retained-custody destination-envelope schemas locally.
data TargetWorkerRewrapBoundary m = TargetWorkerRewrapBoundary
  { materializeRewrappedSesSmtp
      :: CredentialGeneration
      -> ByteString
      -> m (Either Text TargetSecretPayload)
  , materializeRewrappedAcmeEab
      :: CredentialGeneration
      -> ByteString
      -> m (Either Text TargetSecretPayload)
  }

-- | Production destination-envelope opener.  X25519 private-key bytes exist
-- only inside the bounded stdin opening frame; the callback returns one closed
-- Target payload and retains no generic decrypt or arbitrary-path operation.
retainedTargetWorkerRewrapBoundary
  :: (Applicative m) => TargetWorkerRewrapBoundary m
retainedTargetWorkerRewrapBoundary =
  TargetWorkerRewrapBoundary
    { materializeRewrappedSesSmtp = \generation envelope ->
        pure
          ( first
              (const "retained SES SMTP destination envelope was refused")
              ( openRetainedDestinationOpeningForGeneration
                  SRetainedSesSmtpMaterial
                  generation
                  envelope
              )
          )
    , materializeRewrappedAcmeEab = \generation envelope ->
        pure
          ( first
              (const "retained ACME EAB destination envelope was refused")
              ( openRetainedDestinationOpeningForGeneration
                  SRetainedAcmeEabMaterial
                  generation
                  envelope
              )
          )
    }

data TargetSecretWorkerRuntimeError
  = TargetSecretWorkerStdinReadFailed
  | TargetSecretWorkerStdinTooLarge !Int !Int
  | TargetSecretWorkerFrameRejected !TargetWorkerIngressError
  | TargetSecretWorkerPodUidReadFailed
  | TargetSecretWorkerPodUidInvalid
  | TargetSecretWorkerPodNameReadFailed
  | TargetSecretWorkerPodNameInvalid
  | TargetSecretWorkerFrameBindingMismatch
  | TargetSecretWorkerClockUnavailable
  | TargetSecretWorkerVaultLoginUnavailable
  | TargetSecretWorkerCleanupAuthorizationUnavailable
  | TargetSecretWorkerVaultSessionCleanupUnavailable
  | TargetSecretWorkerTrustUnavailable
  | TargetSecretWorkerIntentRejected
  | TargetSecretWorkerExecutionPermitRejected !TargetWorkerExecutionPermitError
  | TargetSecretWorkerAttestationRejected
  | TargetSecretWorkerRewrapUnavailable
  | TargetSecretWorkerExecutionRefused !TargetWorkerExecutionError
  | TargetSecretWorkerOperationRefused
  | TargetSecretWorkerTlsRetainProductionBoundaryUnavailable
  | TargetSecretWorkerTlsRetainFailed !TlsTargetAgentError
  | TargetSecretWorkerTlsRetainBadRequest
  | TargetSecretWorkerTlsHomeRewrapFailed !TlsTargetAgentError
  | TargetSecretWorkerTlsHomeRewrapBadRequest
  | TargetSecretWorkerTlsRestoreProductionBoundaryUnavailable
  | TargetSecretWorkerTlsRestoreFailed !TlsTargetAgentError
  | TargetSecretWorkerTlsRestoreBadRequest
  | TargetSecretWorkerUnhandledException
  deriving stock (Eq, Show)

-- | Closed, value-free refusal carried by the authenticated provisional
-- frame. Existing non-TLS failures retain their rollout token; TLS operations
-- are refined only far enough to select their exact typed failure family.
renderTargetSecretWorkerRuntimeRefusal :: TargetSecretWorkerRuntimeError -> Text
renderTargetSecretWorkerRuntimeRefusal runtimeError = case runtimeError of
  TargetSecretWorkerTlsRetainProductionBoundaryUnavailable ->
    "tls-retain/production-boundary-unavailable"
  TargetSecretWorkerTlsRetainFailed targetError ->
    "tls-retain/" <> renderTlsTargetAgentError targetError
  TargetSecretWorkerTlsRetainBadRequest -> "tls-retain/bad-request"
  TargetSecretWorkerTlsHomeRewrapFailed targetError ->
    "tls-home-rewrap/" <> renderTlsHomeRewrapTargetError targetError
  TargetSecretWorkerTlsHomeRewrapBadRequest -> "tls-home-rewrap/bad-request"
  TargetSecretWorkerTlsRestoreProductionBoundaryUnavailable ->
    "tls-restore/production-boundary-unavailable"
  TargetSecretWorkerTlsRestoreFailed targetError ->
    "tls-restore/" <> renderTlsTargetAgentError targetError
  TargetSecretWorkerTlsRestoreBadRequest -> "tls-restore/bad-request"
  _ -> "target-worker-materialization-refused"

renderTlsHomeRewrapTargetError :: TlsTargetAgentError -> Text
renderTlsHomeRewrapTargetError targetError = case targetError of
  TlsTargetDekExchangeFailed exchangeError ->
    "dek-exchange-failed/"
      <> renderTlsDekExchangeRefusalCause
        (classifyTlsDekExchangeError exchangeError)
      <> renderTlsDekTransitFailureSuffix exchangeError
  _ -> "other-target-error"

renderTlsDekTransitFailureSuffix :: TlsDekExchangeError -> Text
renderTlsDekTransitFailureSuffix exchangeError = case exchangeError of
  TlsDekTransitUnwrapUnavailable failure ->
    "/" <> renderTlsDekTransitFailure failure
  _ -> ""

data TlsDekExchangeRefusalCause
  = TlsDekRefusalLengthInvalid
  | TlsDekRefusalPublicKeyInvalid
  | TlsDekRefusalSecretKeyInvalid
  | TlsDekRefusalPrivateTokenInvalid
  | TlsDekRefusalPrivateTokenUnavailable
  | TlsDekRefusalEnvelopeBindingMismatch
  | TlsDekRefusalEnvelopeVersionUnsupported
  | TlsDekRefusalCipherFailed
  | TlsDekRefusalTransitWrapUnavailable
  | TlsDekRefusalTransitUnwrapUnavailable
  | TlsDekRefusalWrappedCiphertextInvalid
  deriving stock (Bounded, Enum, Eq, Show)

classifyTlsDekExchangeError :: TlsDekExchangeError -> TlsDekExchangeRefusalCause
classifyTlsDekExchangeError exchangeError = case exchangeError of
  TlsDekLengthInvalid _ -> TlsDekRefusalLengthInvalid
  TlsDekPublicKeyInvalid -> TlsDekRefusalPublicKeyInvalid
  TlsDekSecretKeyInvalid -> TlsDekRefusalSecretKeyInvalid
  TlsDekPrivateTokenInvalid -> TlsDekRefusalPrivateTokenInvalid
  TlsDekPrivateTokenUnavailable _ -> TlsDekRefusalPrivateTokenUnavailable
  TlsDekEnvelopeBindingMismatch -> TlsDekRefusalEnvelopeBindingMismatch
  TlsDekEnvelopeVersionUnsupported _ -> TlsDekRefusalEnvelopeVersionUnsupported
  TlsDekCipherFailed _ -> TlsDekRefusalCipherFailed
  TlsDekTransitWrapUnavailable _ -> TlsDekRefusalTransitWrapUnavailable
  TlsDekTransitUnwrapUnavailable _ -> TlsDekRefusalTransitUnwrapUnavailable
  TlsDekWrappedCiphertextInvalid -> TlsDekRefusalWrappedCiphertextInvalid

renderTlsDekExchangeRefusalCause :: TlsDekExchangeRefusalCause -> Text
renderTlsDekExchangeRefusalCause cause = case cause of
  TlsDekRefusalLengthInvalid -> "length-invalid"
  TlsDekRefusalPublicKeyInvalid -> "public-key-invalid"
  TlsDekRefusalSecretKeyInvalid -> "secret-key-invalid"
  TlsDekRefusalPrivateTokenInvalid -> "private-token-invalid"
  TlsDekRefusalPrivateTokenUnavailable -> "private-token-unavailable"
  TlsDekRefusalEnvelopeBindingMismatch -> "envelope-binding-mismatch"
  TlsDekRefusalEnvelopeVersionUnsupported -> "envelope-version-unsupported"
  TlsDekRefusalCipherFailed -> "cipher-failed"
  TlsDekRefusalTransitWrapUnavailable -> "transit-wrap-unavailable"
  TlsDekRefusalTransitUnwrapUnavailable -> "transit-unwrap-unavailable"
  TlsDekRefusalWrappedCiphertextInvalid -> "wrapped-ciphertext-invalid"

renderTlsDekTransitFailure :: TlsDekTransitFailure -> Text
renderTlsDekTransitFailure failure = case failure of
  TlsDekTransitSessionAcquisitionSealed -> "session-acquisition-sealed"
  TlsDekTransitSessionAcquisitionForbidden -> "session-acquisition-forbidden"
  TlsDekTransitSessionAcquisitionUnavailable -> "session-acquisition-unavailable"
  TlsDekTransitSessionReloginSealed -> "session-relogin-sealed"
  TlsDekTransitSessionReloginForbidden -> "session-relogin-forbidden"
  TlsDekTransitSessionReloginUnavailable -> "session-relogin-unavailable"
  TlsDekTransitRequestBadRequestMissingCiphertext ->
    "request-bad-request/missing-ciphertext"
  TlsDekTransitRequestBadRequestKeyNotFound ->
    "request-bad-request/key-not-found"
  TlsDekTransitRequestBadRequestCiphertextNoPrefix ->
    "request-bad-request/ciphertext-no-prefix"
  TlsDekTransitRequestBadRequestCiphertextWrongFields ->
    "request-bad-request/ciphertext-wrong-fields"
  TlsDekTransitRequestBadRequestCiphertextVersionUndecodable ->
    "request-bad-request/ciphertext-version-undecodable"
  TlsDekTransitRequestBadRequestCiphertextVersionTooNew ->
    "request-bad-request/ciphertext-version-too-new"
  TlsDekTransitRequestBadRequestCiphertextVersionTooOld ->
    "request-bad-request/ciphertext-version-too-old"
  TlsDekTransitRequestBadRequestConvergentNonceInvalid ->
    "request-bad-request/convergent-nonce-invalid"
  TlsDekTransitRequestBadRequestCiphertextBase64Invalid ->
    "request-bad-request/ciphertext-base64-invalid"
  TlsDekTransitRequestBadRequestCiphertextLengthInvalid ->
    "request-bad-request/ciphertext-length-invalid"
  TlsDekTransitRequestBadRequestCiphertextAuthenticationFailed ->
    "request-bad-request/ciphertext-authentication-failed"
  TlsDekTransitRequestBadRequestOther -> "request-bad-request/other"
  TlsDekTransitRequestUnauthorized -> "request-unauthorized"
  TlsDekTransitRequestForbidden -> "request-forbidden"
  TlsDekTransitRequestNotFound -> "request-not-found"
  TlsDekTransitRequestThrottled -> "request-throttled"
  TlsDekTransitRequestClientFailure -> "request-client-failure"
  TlsDekTransitRequestServerFailure -> "request-server-failure"
  TlsDekTransitRequestUnexpectedStatus -> "request-unexpected-status"
  TlsDekTransitRequestConnectionFailure -> "request-connection-failure"
  TlsDekTransitRequestTimeout -> "request-timeout"
  TlsDekTransitRequestDecodeFailure -> "request-decode-failure"
  TlsDekTransitUnexpectedException -> "unexpected-exception"

-- | Exact home-rewrap runtime tokens admitted by the standing Target Agent.
targetSecretWorkerTlsHomeRewrapRefusalTokens :: [Text]
targetSecretWorkerTlsHomeRewrapRefusalTokens =
  ["tls-home-rewrap/bad-request", "tls-home-rewrap/other-target-error"]
    <> [ "tls-home-rewrap/dek-exchange-failed/"
           <> renderTlsDekExchangeRefusalCause cause
       | cause <- [minBound .. maxBound]
       , cause /= TlsDekRefusalTransitUnwrapUnavailable
       ]
    <> [ "tls-home-rewrap/dek-exchange-failed/transit-unwrap-unavailable/"
           <> renderTlsDekTransitFailure failure
       | failure <- [minBound .. maxBound]
       ]

-- | Promote only the exact Transit authentication-failed observation to a
-- typed, payload-free operation result. Every other failure remains on the
-- ordinary refused-completion path.
classifyTlsHomeRewrapWorkerResult
  :: TlsHomeRewrapResult
  -> Either TargetSecretWorkerRuntimeError TargetWorkerOperationResult
classifyTlsHomeRewrapWorkerResult result = case result of
  TlsHomeRewrapped envelope -> Right (TargetWorkerTlsHomeRewrappedResult envelope)
  TlsHomeRewrapFailed
    ( TlsTargetDekExchangeFailed
        ( TlsDekTransitUnwrapUnavailable
            TlsDekTransitRequestBadRequestCiphertextAuthenticationFailed
          )
      ) ->
      Right TargetWorkerTlsHomeRewrapCiphertextAuthenticationFailedResult
  TlsHomeRewrapFailed err -> Left (TargetSecretWorkerTlsHomeRewrapFailed err)
  TlsHomeRewrapBadRequest _ -> Left TargetSecretWorkerTlsHomeRewrapBadRequest
  TlsHomeRewrapCiphertextAuthenticationFailed ->
    Right TargetWorkerTlsHomeRewrapCiphertextAuthenticationFailedResult

renderTlsTargetAgentError :: TlsTargetAgentError -> Text
renderTlsTargetAgentError targetError = case targetError of
  TlsTargetSecretUnavailable -> "secret-unavailable"
  TlsTargetSecretInvalid -> "secret-invalid"
  TlsTargetSecretReadBackMismatch -> "secret-readback-mismatch"
  TlsTargetSecretApplyFailed failure ->
    "secret-apply-failed/" <> renderTlsSecretApplyFailure failure
  TlsTargetDekExchangeFailed _ -> "dek-exchange-failed"
  TlsTargetCipherFailed _ -> "cipher-failed"
  TlsTargetCertificateCiphertextInvalid -> "certificate-ciphertext-invalid"
  TlsTargetCertificateCiphertextTooLarge _ _ -> "certificate-ciphertext-too-large"
  TlsTargetReferenceMismatch -> "reference-mismatch"

renderTlsSecretApplyFailure :: TlsSecretApplyFailure -> Text
renderTlsSecretApplyFailure failure = case failure of
  TlsSecretApplyInitialObservationUnavailable -> "initial-observation-unavailable"
  TlsSecretApplyRestoreSlotMissing -> "restore-slot-missing"
  TlsSecretApplyExistingCorrupt -> "existing-corrupt"
  TlsSecretApplyExistingContentMismatch -> "existing-content-mismatch"
  TlsSecretApplyRequestInvalid -> "request-invalid"
  TlsSecretApplyTransportUnavailable -> "transport-unavailable"
  TlsSecretApplyBadRequest -> "http-bad-request"
  TlsSecretApplyUnauthorized -> "http-unauthorized"
  TlsSecretApplyForbidden -> "http-forbidden"
  TlsSecretApplyNotFound -> "http-not-found"
  TlsSecretApplyMethodNotAllowed -> "http-method-not-allowed"
  TlsSecretApplyConflict -> "http-conflict"
  TlsSecretApplyUnsupportedMediaType -> "http-unsupported-media-type"
  TlsSecretApplyUnprocessable -> "http-unprocessable"
  TlsSecretApplyThrottled -> "http-throttled"
  TlsSecretApplyServerUnavailable -> "http-server-unavailable"
  TlsSecretApplyUnexpectedStatus -> "http-unexpected-status"
  TlsSecretApplyReadBackUnavailable -> "read-back-unavailable"
  TlsSecretApplyReadBackMissing -> "read-back-missing"
  TlsSecretApplyReadBackRestoreSlot -> "read-back-restore-slot"
  TlsSecretApplyReadBackCorrupt -> "read-back-corrupt"
  TlsSecretApplyReadBackContentMismatch -> "read-back-content-mismatch"

-- | Exact TLS apply tokens which a standing Target Agent may admit from an
-- authenticated one-shot worker refusal.
targetSecretWorkerTlsApplyRefusalTokens :: [Text]
targetSecretWorkerTlsApplyRefusalTokens =
  [ operation
      <> "/secret-apply-failed/"
      <> renderTlsSecretApplyFailure failure
  | operation <- ["tls-retain", "tls-restore"]
  , failure <- [minBound .. maxBound]
  ]

targetSecretWorkerCommitmentKey :: Text
targetSecretWorkerCommitmentKey = "prodbox-target-secret-commitment"

targetSecretWorkerTrustPath :: TargetSecretId -> Text
targetSecretWorkerTrustPath target =
  "target-agent/trust/" <> targetSecretIdToken target

runTargetSecretWorker :: TargetSecretWorkerOptions -> IO ExitCode
runTargetSecretWorker =
  runTargetSecretWorkerWithRewrap retainedTargetWorkerRewrapBoundary

runTargetSecretWorkerWithRewrap
  :: TargetWorkerRewrapBoundary IO
  -> TargetSecretWorkerOptions
  -> IO ExitCode
runTargetSecretWorkerWithRewrap rewrap options = do
  result <- runWorker rewrap options stdioProvisionalBoundary
  case result of
    Left err -> do
      -- The error algebra contains no frame, payload, token, Vault body, or
      -- secret-derived digest.
      writeDiagnosticLine ("target-secret worker refused: " <> show err)
      pure (ExitFailure 1)
    Right _ -> pure ExitSuccess

runWorker
  :: TargetWorkerRewrapBoundary IO
  -> TargetSecretWorkerOptions
  -> ( TargetWorkerProvisionalCompletion
       -> IO (Either TargetSecretWorkerRuntimeError ())
     )
  -> IO
       ( Either
           TargetSecretWorkerRuntimeError
           TargetWorkerOperationResult
       )
runWorker rewrap options provisionalBoundary = do
  stdinResult <- readFramedHandleBounded targetWorkerIngressMaximumBytes stdin
  podUidResult <- readTargetWorkerPodUid (targetSecretWorkerPodUidFile options)
  podNameResult <- readTargetWorkerPodName (targetSecretWorkerPodNameFile options)
  case (stdinResult, podUidResult, podNameResult) of
    (Left err, _, _) -> pure (Left err)
    (_, Left err, _) -> pure (Left err)
    (_, _, Left err) -> pure (Left err)
    (Right input, Right actualPodUid, Right actualPodName) ->
      case withTargetWorkerOperationIngress
        input
        (executeFrame actualPodUid actualPodName) of
        Left err -> pure (Left (TargetSecretWorkerFrameRejected err))
        Right effect -> effect
 where
  executeFrame
    :: TargetWorkerPodUid
    -> Text
    -> TargetWorkerFrameBinding
    -> TargetWorkerOperationInput
    -> IO
         ( Either
             TargetSecretWorkerRuntimeError
             TargetWorkerOperationResult
         )
  executeFrame actualPodUid actualPodName binding operation
    | targetWorkerFramePodUid binding /= actualPodUid = bindingMismatch
    | targetWorkerFramePodName binding /= actualPodName = bindingMismatch
    | targetWorkerFrameTarget binding /= targetSecretWorkerExpectedTarget options = bindingMismatch
    | targetWorkerFrameSchema binding /= targetSecretWorkerExpectedSchema options = bindingMismatch
    | targetWorkerFrameImageDigest binding /= targetSecretWorkerExpectedImageDigest options =
        bindingMismatch
    | targetWorkerFrameRequestDigest binding /= targetSecretWorkerExpectedRequestDigest options =
        bindingMismatch
    | targetWorkerFrameDeadline binding /= targetSecretWorkerExpectedDeadline options = bindingMismatch
    | otherwise =
        withClosedWorkerVaultSession
          options
          (targetWorkerFrameServiceAccount binding)
          (targetWorkerFrameServiceAccountUid binding)
          (targetWorkerFrameSessionFence binding)
          provisionalBoundary
          ( authorizeWorkerPreclean
              (targetSecretWorkerExpectedAgentIdentity options)
              actualPodUid
              actualPodName
              binding
          )
          ( \session ->
              executeAuthenticated
                session
                (targetSecretWorkerExpectedAgentIdentity options)
                actualPodUid
                actualPodName
                binding
                operation
                rewrap
          )
   where
    bindingMismatch = pure (Left TargetSecretWorkerFrameBindingMismatch)

executeAuthenticated
  :: VaultSession
  -> TargetAgentIdentity
  -> TargetWorkerPodUid
  -> Text
  -> TargetWorkerFrameBinding
  -> TargetWorkerOperationInput
  -> TargetWorkerRewrapBoundary IO
  -> IO
       ( Either
           TargetSecretWorkerRuntimeError
           TargetWorkerOperationResult
       )
executeAuthenticated session agentIdentity actualPodUid actualPodName binding operation rewrap = do
  trustResult <- readAcceptedAuthority session (targetWorkerFrameTarget binding)
  nowResult <- currentTime
  case (nowResult, trustResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right now, Right accepted) ->
      case authenticateTargetWorkerFrame now accepted agentIdentity actualPodUid actualPodName binding of
        Left err -> pure (Left err)
        Right (attestation, _) -> executeOperation session rewrap attestation operation

-- This check is pure so callers can authenticate the same binding before
-- entering any effectful session lifecycle as well as before materialization.
authenticateTargetWorkerFrame
  :: AuthorityTime
  -> AcceptedTargetAuthority
  -> TargetAgentIdentity
  -> TargetWorkerPodUid
  -> Text
  -> TargetWorkerFrameBinding
  -> Either TargetSecretWorkerRuntimeError (TargetWorkerAttestation, ServiceSessionBinding)
authenticateTargetWorkerFrame now accepted agentIdentity actualPodUid actualPodName binding = do
  intent <-
    first (const TargetSecretWorkerIntentRejected) $
      prepareTargetWorkerIntent
        accepted
        now
        agentIdentity
        (targetWorkerFrameTarget binding)
        (targetWorkerFrameSchema binding)
        (targetWorkerFrameImageDigest binding)
        (targetWorkerFrameSignedIntent binding)
  if targetWorkerIntentRequestDigest intent /= targetWorkerFrameRequestDigest binding
    || targetWorkerIntentServiceAccount intent /= targetWorkerFrameServiceAccount binding
    || targetWorkerIntentDeadline intent /= targetWorkerFrameDeadline binding
    then Left TargetSecretWorkerFrameBindingMismatch
    else pure ()
  permit <-
    first TargetSecretWorkerExecutionPermitRejected $
      verifyTargetWorkerExecutionPermit
        accepted
        now
        intent
        (targetWorkerFrameExecutionPermit binding)
  if verifiedPermitJobName permit /= targetWorkerFrameJobName binding
    || verifiedPermitJobUid permit /= targetWorkerFrameJobUid binding
    || verifiedPermitPodName permit /= targetWorkerFramePodName binding
    || verifiedPermitPodUid permit /= targetWorkerFramePodUid binding
    || verifiedPermitServiceAccount permit /= targetWorkerFrameServiceAccount binding
    || verifiedPermitServiceAccountUid permit /= targetWorkerFrameServiceAccountUid binding
    || verifiedPermitImageDigest permit /= targetWorkerFrameImageDigest binding
    || verifiedPermitRequestDigest permit /= targetWorkerFrameRequestDigest binding
    || serviceSessionBindingFence (verifiedPermitSessionBinding permit)
      /= targetWorkerFrameSessionFence binding
    then Left TargetSecretWorkerFrameBindingMismatch
    else pure ()
  attestation <-
    first (const TargetSecretWorkerAttestationRejected) $
      attestTargetWorkerPod
        now
        intent
        ( runtimeObservation
            agentIdentity
            intent
            (verifiedPermitJobUid permit)
            actualPodUid
            actualPodName
            (targetWorkerFrameServiceAccountUid binding)
        )
  pure (attestation, verifiedPermitSessionBinding permit)

executeOperation
  :: VaultSession
  -> TargetWorkerRewrapBoundary IO
  -> TargetWorkerAttestation
  -> TargetWorkerOperationInput
  -> IO (Either TargetSecretWorkerRuntimeError TargetWorkerOperationResult)
executeOperation session rewrap attestation operation = case operation of
  TargetWorkerDirectMaterialInput payload -> materialize payload
  TargetWorkerRewrappedSesSmtpInput envelope -> do
    resolved <-
      materializeRewrappedSesSmtp
        rewrap
        (targetWorkerIntentGeneration intent)
        envelope
    case resolved of
      Left _ -> operationRefused
      Right payload -> materialize payload
  TargetWorkerRewrappedAcmeEabInput envelope -> do
    resolved <-
      materializeRewrappedAcmeEab
        rewrap
        (targetWorkerIntentGeneration intent)
        envelope
    case resolved of
      Left _ -> operationRefused
      Right payload -> materialize payload
  TargetWorkerTlsPrepareInput -> do
    result <- prepareTlsTargetExchange transit
    pure $ case result of
      TlsTargetPrepared prepared -> Right (TargetWorkerTlsPreparedResult prepared)
      _ -> Left TargetSecretWorkerOperationRefused
  TargetWorkerTlsRetainInput request -> do
    boundaries <- tlsTargetAgentProductionBoundaries session
    case boundaries of
      Left _ -> pure (Left TargetSecretWorkerTlsRetainProductionBoundaryUnavailable)
      Right (secretBoundary, _) -> do
        result <-
          retainTlsAtSelectedAgent
            secretBoundary
            (tlsTargetRetainVersion request)
            (tlsTargetRetainHomePublicKey request)
        pure $ case result of
          TlsTargetRetained receipt -> Right (TargetWorkerTlsRetainedResult receipt)
          TlsTargetRetainMissing -> Right TargetWorkerTlsRetainMissingResult
          TlsTargetRetainFailed err -> Left (TargetSecretWorkerTlsRetainFailed err)
          TlsTargetRetainBadRequest _ -> Left TargetSecretWorkerTlsRetainBadRequest
  TargetWorkerTlsHomeWrapInput request -> do
    result <-
      wrapTlsDekAtHomeAgent
        transit
        (tlsHomeWrapPrepared request)
        (tlsHomeWrapEnvelope request)
    pure $ case result of
      TlsHomeWrapped wrapped -> Right (TargetWorkerTlsHomeWrappedResult wrapped)
      _ -> Left TargetSecretWorkerOperationRefused
  TargetWorkerTlsHomeRewrapInput request -> do
    result <-
      rewrapTlsDekAtHomeAgent
        transit
        (tlsHomeRewrapWrappedDek request)
        (tlsHomeRewrapTargetPublicKey request)
    pure (classifyTlsHomeRewrapWorkerResult result)
  TargetWorkerTlsRestoreInput request -> do
    boundaries <- tlsTargetAgentProductionBoundaries session
    case boundaries of
      Left _ -> pure (Left TargetSecretWorkerTlsRestoreProductionBoundaryUnavailable)
      Right (secretBoundary, _) -> do
        result <-
          restoreTlsAtSelectedAgent
            secretBoundary
            transit
            (tlsTargetRestoreReference request)
            (tlsTargetRestorePrepared request)
            (tlsTargetRestoreDekEnvelope request)
            (tlsTargetRestoreCertificateCiphertext request)
        pure $ case result of
          TlsTargetRestored receipt -> Right (TargetWorkerTlsRestoredResult receipt)
          TlsTargetRestoreFailed err -> Left (TargetSecretWorkerTlsRestoreFailed err)
          TlsTargetRestoreBadRequest _ -> Left TargetSecretWorkerTlsRestoreBadRequest
  TargetWorkerTlsVerifyInput request -> do
    boundaries <- tlsTargetAgentProductionBoundaries session
    case boundaries of
      Left _ -> operationRefused
      Right (secretBoundary, _) -> do
        result <-
          verifyTlsSourceAtSelectedAgent
            secretBoundary
            (tlsTargetVerifyReference request)
        pure $ case result of
          TlsTargetSourceVerified receipt -> Right (TargetWorkerTlsVerifiedResult receipt)
          TlsTargetVerifyMissing -> Right TargetWorkerTlsVerifyMissingResult
          TlsTargetVerifyMismatch cause -> Right (TargetWorkerTlsVerifyMismatchResult cause)
          _ -> Left TargetSecretWorkerOperationRefused
  TargetWorkerFederationCustodyCommitInput supplied ->
    case (validateFederationRegistrationIntent supplied, federationRegistrationTargetAgent supplied) of
      (Right validated, Right selectedAgent)
        | selectedAgent == targetWorkerIntentAgentIdentity intent -> do
            committed <-
              commitTargetChildCustody
                (vaultTargetChildCustodyRepository session noRoleReadinessContribution)
                (childCustodyExportReceipt (federationRegistrationExport validated))
            pure $ case committed of
              Left _ -> Left TargetSecretWorkerOperationRefused
              Right acknowledgement ->
                Right
                  ( TargetWorkerFederationCustodyCommittedResult
                      acknowledgement
                  )
      _ -> operationRefused
  TargetWorkerFederationRecoveryPrepareInput binding nonce childAttestation -> do
    prepared <-
      prepareTargetChildRecovery
        custody
        binding
        nonce
        childAttestation
    pure $ case prepared of
      Left _ -> Left TargetSecretWorkerOperationRefused
      Right delivery ->
        Right (TargetWorkerFederationRecoveryPreparedResult delivery)
  TargetWorkerFederationRecoveryObserveInput delivery -> do
    observed <- observeTargetChildRecovery custody delivery
    pure $ case observed of
      Left _ -> Left TargetSecretWorkerOperationRefused
      Right observation ->
        Right (TargetWorkerFederationRecoveryObservedResult observation)
  TargetWorkerFederationRecoveryCommitInput delivery -> do
    committed <- commitTargetChildRecoveryConsumption custody delivery
    pure $ case committed of
      Left _ -> Left TargetSecretWorkerOperationRefused
      Right observation ->
        Right (TargetWorkerFederationRecoveryCommittedResult observation)
 where
  intent = targetWorkerAttestedIntent attestation
  transit = tlsDekVaultBoundary session
  custody = vaultTargetChildCustodyRepository session noRoleReadinessContribution
  operationRefused = pure (Left TargetSecretWorkerOperationRefused)

  materialize payload = do
    executionNow <- currentTime
    case executionNow of
      Left err -> pure (Left err)
      Right current -> do
        materialized <-
          executeTargetWorkerMaterialization
            current
            (vaultTargetWorkerBoundary session)
            attestation
            payload
        pure $ case materialized of
          Left err -> Left (TargetSecretWorkerExecutionRefused err)
          Right result -> Right (TargetWorkerMaterializedResult (materializationReceipt result))

runtimeObservation
  :: TargetAgentIdentity
  -> TargetWorkerIntent
  -> TargetWorkerJobUid
  -> TargetWorkerPodUid
  -> Text
  -> TargetWorkerServiceAccountUid
  -> RawTargetWorkerPodObservation
runtimeObservation agentIdentity intent jobUid podUid podName serviceAccountUid =
  RawTargetWorkerPodObservation
    { observedTargetWorkerJobName = targetWorkerIntentJobName intent
    , observedTargetWorkerJobUid = targetWorkerJobUidText jobUid
    , observedTargetWorkerPodName = podName
    , observedTargetWorkerPodUid = targetWorkerPodUidText podUid
    , observedTargetWorkerImageDigest =
        targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
    , observedTargetWorkerServiceAccount = targetWorkerIntentServiceAccount intent
    , observedTargetWorkerServiceAccountUid =
        targetWorkerServiceAccountUidText serviceAccountUid
    , observedTargetWorkerTarget = targetSecretIdToken (targetWorkerIntentTarget intent)
    , observedTargetWorkerAgentIdentity =
        targetAgentIdentityText agentIdentity
    , observedTargetWorkerSchema = targetWorkerSchemaToken (targetWorkerIntentSchema intent)
    , observedTargetWorkerRequestDigest =
        targetValueDigestText (targetWorkerIntentRequestDigest intent)
    , observedTargetWorkerDeadlineMicros = authorityTimeMicros (targetWorkerIntentDeadline intent)
    , observedTargetWorkerPhase = "Running"
    , observedTargetWorkerReady = True
    , observedTargetWorkerRestartCount = 0
    , observedTargetWorkerDeletionTimestamp = Nothing
    }

readAcceptedAuthority
  :: VaultSession
  -> TargetSecretId
  -> IO (Either TargetSecretWorkerRuntimeError AcceptedTargetAuthority)
readAcceptedAuthority session target = do
  result <-
    withSessionToken session $ \token ->
      vaultKvReadV2
        (sessionAddress session)
        token
        "secret"
        (targetSecretWorkerTrustPath target)
  pure $ do
    fields <- first (const TargetSecretWorkerTrustUnavailable) result
    decodeTargetWorkerAcceptedAuthority target fields

decodeTargetWorkerAcceptedAuthority
  :: TargetSecretId
  -> Map.Map Text Text
  -> Either TargetSecretWorkerRuntimeError AcceptedTargetAuthority
decodeTargetWorkerAcceptedAuthority target fields = do
  record <-
    first (const TargetSecretWorkerTrustUnavailable) (decodeTargetAuthorityEpochFields target fields)
  maybe (Left TargetSecretWorkerTrustUnavailable) Right (targetEpochWorkerAuthority record)

vaultTargetWorkerBoundary :: VaultSession -> TargetWorkerVaultBoundary IO
vaultTargetWorkerBoundary session =
  TargetWorkerVaultBoundary
    { targetWorkerReadData = readTargetWorkerData session
    , targetWorkerReadMetadata = readTargetWorkerMetadata session
    , targetWorkerCommitmentHmac = \input -> do
        result <-
          withSessionToken session $ \token ->
            vaultTransitHmacSha256
              (sessionAddress session)
              token
              targetSecretWorkerCommitmentKey
              input
        pure (first (Text.pack . renderHttpError) result)
    , targetWorkerCompareAndSwap = compareAndSwapTargetWorkerData session
    , targetWorkerWriteMetadata = writeTargetWorkerMetadata session
    }

readTargetWorkerData
  :: VaultSession
  -> TargetSecretId
  -> IO (Either Text TargetWorkerDataObservation)
readTargetWorkerData session target = case compiledTargetSecretSink target of
  Left detail -> pure (Left detail)
  Right sink -> do
    result <-
      withSessionToken session $ \token ->
        vaultKvReadVersionedV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
    pure $ case result of
      Left (HttpStatus 404 _) -> Right TargetWorkerDataMissing
      Left err -> Left (Text.pack (renderHttpError err))
      Right versioned ->
        Right
          ( TargetWorkerDataPresent
              (kvV2VersionedSecretVersion versioned)
              (kvV2VersionedSecretData versioned)
          )

readTargetWorkerMetadata
  :: VaultSession
  -> TargetSecretId
  -> IO (Either Text TargetWorkerMetadataObservation)
readTargetWorkerMetadata session target = case compiledTargetSecretSink target of
  Left detail -> pure (Left detail)
  Right sink -> do
    result <-
      withSessionToken session $ \token ->
        vaultKvReadMetadataV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
    pure $ case result of
      Left (HttpStatus 404 _) -> Right TargetWorkerMetadataMissing
      Left err -> Left (Text.pack (renderHttpError err))
      Right metadata ->
        Right
          ( TargetWorkerMetadataPresent
              (kvV2SecretMetadataCurrentVersion metadata)
              (kvV2SecretMetadataCustom metadata)
          )

compareAndSwapTargetWorkerData
  :: VaultSession
  -> TargetSecretId
  -> Natural
  -> Map.Map Text Text
  -> IO (Either Text Natural)
compareAndSwapTargetWorkerData session target expected fields =
  case compiledTargetSecretSink target of
    Left detail -> pure (Left detail)
    Right sink -> do
      result <-
        withSessionToken session $ \token ->
          vaultKvCasWriteV2
            (sessionAddress session)
            token
            (targetSecretSinkVaultMount sink)
            (targetSecretSinkKvPath sink)
            (KvV2Cas expected)
            fields
      -- Sprint 4.74: the target sink's CAS answers three different facts, and
      -- the commit fold this feeds already distinguishes them on the
      -- object-store lane; this lane stops collapsing them into one string.
      pure $ case classifyVaultCasOutcome result of
        VaultCasApplied version -> Right version
        failed -> Left (renderVaultCasOutcome failed)

writeTargetWorkerMetadata
  :: VaultSession
  -> TargetSecretId
  -> Map.Map Text Text
  -> IO (Either Text ())
writeTargetWorkerMetadata session target fields = case compiledTargetSecretSink target of
  Left detail -> pure (Left detail)
  Right sink -> do
    result <-
      withSessionToken session $ \token ->
        vaultKvWriteCustomMetadataV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
          fields
    pure (first (Text.pack . renderHttpError) result)

data WorkerVaultLogin = WorkerVaultLogin
  { workerLoginSession :: !VaultSession
  , workerLoginAccessor :: !Text
  , workerLoginJwt :: !Text
  }

newWorkerVaultSession
  :: Text -> IO (Either TargetSecretWorkerRuntimeError WorkerVaultLogin)
newWorkerVaultSession jwt = do
  result <-
    vaultKubernetesLoginWithLease
      workerVaultAddress
      workerVaultAuthPath
      targetSecretWorkerVaultRole
      jwt
  case result of
    Left _ -> pure (Left TargetSecretWorkerVaultLoginUnavailable)
    Right login
      | not (targetWorkerServiceLoginAccepted login) -> do
          _ <- vaultRevokeSelf workerVaultAddress (vaultLoginToken login)
          pure (Left TargetSecretWorkerVaultLoginUnavailable)
      | otherwise -> do
          session <-
            newVaultSession
              workerVaultAddress
              realSessionClock
              ( pure
                  ( Right
                      LoginLease
                        { loginLeaseToken = vaultLoginToken login
                        , loginLeaseSeconds = vaultLoginLeaseSeconds login
                        , loginLeaseRenewable = vaultLoginRenewable login
                        }
                  )
              )
          pure
            ( Right
                WorkerVaultLogin
                  { workerLoginSession = session
                  , workerLoginAccessor = Text.strip (vaultLoginAccessor login)
                  , workerLoginJwt = jwt
                  }
            )

-- | Service tokens may be renewable according to Vault Kubernetes-auth
-- semantics. Their server-side role caps, reconciled separately, bound the
-- hard lifetime; runtime evidence must still be an accessor-bearing service
-- token with a positive lease no greater than that cap.
targetWorkerServiceLoginAccepted :: VaultKubernetesLoginResult -> Bool
targetWorkerServiceLoginAccepted login =
  vaultLoginTokenType login == "service"
    && not (Text.null (Text.strip (vaultLoginAccessor login)))
    && vaultLoginLeaseSeconds login > 0
    && vaultLoginLeaseSeconds login <= workerMaximumLeaseSeconds

-- | Masked acquisition/use/cleanup for every worker terminal path. A lost
-- Kubernetes-login response is still treated as a possibly issued service
-- token. The same projected identity obtains exactly one accessor-free batch
-- auditor, correlates accessors by exact policy plus ServiceAccount UID,
-- revokes them, and requires two fresh zero-member inventories.
-- The auditor may only touch the role after verifying the current signed
-- binding and observing its issued journal entry.  The durable physical fence
-- is still needed to cover changes after this observation.
authorizeWorkerPreclean
  :: TargetAgentIdentity
  -> TargetWorkerPodUid
  -> Text
  -> TargetWorkerFrameBinding
  -> VaultKubernetesLoginResult
  -> IO (Either TargetSecretWorkerRuntimeError ServiceSessionBinding)
authorizeWorkerPreclean agent podUid podName binding auditor = do
  session <-
    newVaultSession
      workerVaultAddress
      realSessionClock
      ( pure
          ( Right
              LoginLease
                { loginLeaseToken = vaultLoginToken auditor
                , loginLeaseSeconds = vaultLoginLeaseSeconds auditor
                , loginLeaseRenewable = False
                }
          )
      )
  trustResult <- readAcceptedAuthority session (targetWorkerFrameTarget binding)
  nowResult <- currentTime
  case (nowResult, trustResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right now, Right accepted) ->
      case authenticateTargetWorkerFrame now accepted agent podUid podName binding of
        Left err -> pure (Left err)
        Right (_, expectedBinding) -> do
          observed <-
            readServiceSessionJournal
              ( vaultServiceSessionJournalRepository
                  workerVaultAddress
                  (vaultLoginToken auditor)
                  targetSecretWorkerVaultRole
              )
          pure $ case observed of
            Right snapshot
              | serviceSessionJournalRevision snapshot > 0
              , let journal = serviceSessionJournalObserved snapshot
              , serviceSessionJournalPhase journal == ServiceSessionLoginAttemptCommitted expectedBinding
              , serviceSessionJournalDispatchState journal == Just ServiceSessionDispatchIssued ->
                  Right expectedBinding
            _ -> Left TargetSecretWorkerVaultSessionCleanupUnavailable

-- An inventory must be authorized after Vault has returned it. A stale
-- worker cannot use a newly obtained inventory after its binding changes.
-- This does not settle earlier revokes, logins, or other in-flight effects.
guardTargetWorkerAuditInventory
  :: (Num revision, Ord revision)
  => ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> VaultAccessorAuditOps IO
  -> VaultAccessorAuditOps IO
guardTargetWorkerAuditInventory repository binding ops =
  ops
    { auditListAccessors = do
        inventory <- auditListAccessors ops
        case inventory of
          Left err -> pure (Left err)
          Right accessors -> do
            observed <- readServiceSessionJournal repository
            pure $ case observed of
              Right snapshot
                | serviceSessionJournalRevision snapshot > 0
                , let journal = serviceSessionJournalObserved snapshot
                , serviceSessionJournalDispatchState journal == Just ServiceSessionDispatchIssued
                , workerPhaseMatches binding (serviceSessionJournalPhase journal) ->
                    Right accessors
              _ -> Left "Target worker audit binding is unavailable or no longer issued"
    }
 where
  workerPhaseMatches expected phase = case phase of
    ServiceSessionLoginAttemptCommitted current -> current == expected
    ServiceSessionActive current _ -> current == expected
    _ -> False

withClosedWorkerVaultSession
  :: TargetSecretWorkerOptions
  -> Text
  -> TargetWorkerServiceAccountUid
  -> Natural
  -> ( TargetWorkerProvisionalCompletion
       -> IO (Either TargetSecretWorkerRuntimeError ())
     )
  -> (VaultKubernetesLoginResult -> IO (Either TargetSecretWorkerRuntimeError ServiceSessionBinding))
  -> ( VaultSession
       -> IO
            ( Either
                TargetSecretWorkerRuntimeError
                TargetWorkerOperationResult
            )
     )
  -> IO
       ( Either
           TargetSecretWorkerRuntimeError
           TargetWorkerOperationResult
       )
withClosedWorkerVaultSession options serviceAccount serviceAccountUid _sessionFence provisionalBoundary authorizePreclean action = mask $ \restore -> do
  jwtResult <- readTargetWorkerProjectedToken (targetSecretWorkerServiceAccountTokenFile options)
  case jwtResult of
    Left _ -> pure (Left TargetSecretWorkerVaultLoginUnavailable)
    Right jwt
      | serviceAccount /= targetSecretWorkerVaultRole ->
          pure (Left TargetSecretWorkerFrameBindingMismatch)
      | otherwise -> do
          auditorResult <- newWorkerAuditor jwt
          case auditorResult of
            Left err -> pure (Left err)
            Right auditor -> do
              admitted <- authorizePreclean auditor
              case admitted of
                Left err -> pure (Left err)
                Right binding -> continueWithAuditor restore jwt auditor binding
 where
  continueWithAuditor
    :: (forall a. IO a -> IO a)
    -> Text
    -> VaultKubernetesLoginResult
    -> ServiceSessionBinding
    -> IO (Either TargetSecretWorkerRuntimeError TargetWorkerOperationResult)
  continueWithAuditor restore jwt auditor binding = do
    let auditOps =
          guardTargetWorkerAuditInventory
            ( vaultServiceSessionJournalRepository
                workerVaultAddress
                (vaultLoginToken auditor)
                targetSecretWorkerVaultRole
            )
            binding
            (workerAccessorAuditOps auditor)
    precleaned <-
      revokeAndProveVaultAccessorSubjectAbsent
        auditOps
        (workerAccessorSubject serviceAccountUid)
        Nothing
    case precleaned of
      Left _ -> pure (Left TargetSecretWorkerVaultSessionCleanupUnavailable)
      Right () -> do
        acquired <- tryAny (restore (newWorkerVaultSession jwt))
        case acquired of
          Left exception -> do
            cleanup <- tryAny (auditWorkerSessions auditOps serviceAccountUid Nothing)
            if isAsyncException exception
              then throwIO exception
              else pure (cleanupDominates TargetSecretWorkerVaultLoginUnavailable cleanup)
          Right (Left err) -> do
            cleanup <- tryAny (auditWorkerSessions auditOps serviceAccountUid Nothing)
            pure (cleanupDominates err cleanup)
          Right (Right login) -> do
            attempted <- tryAny (restore (action (workerLoginSession login)))
            case attempted of
              Left _ ->
                finishLogin
                  auditOps
                  login
                  attempted
                  (Right (Left TargetSecretWorkerUnhandledException))
                  False
              Right outcome ->
                case provisionalCompletion (workerLoginAccessor login) outcome of
                  Left err ->
                    finishLogin
                      auditOps
                      login
                      attempted
                      (Right (Left err))
                      False
                  Right completion -> do
                    exchanged <- tryAny (restore (provisionalBoundary completion))
                    finishLogin auditOps login attempted exchanged True
  provisionalCompletion accessor outcome = case outcome of
    Left err ->
      first
        (const TargetSecretWorkerVaultLoginUnavailable)
        ( refusedTargetWorkerProvisionalCompletion
            accessor
            (renderTargetSecretWorkerRuntimeRefusal err)
        )
    Right materialized ->
      first
        (const TargetSecretWorkerVaultLoginUnavailable)
        ( successfulTargetWorkerOperationProvisionalCompletion
            accessor
            materialized
        )

  finishLogin auditOps login attempted exchanged provisionalEmitted = do
    _revoked <-
      tryAny
        ( fmap
            (first (const TargetSecretWorkerVaultSessionCleanupUnavailable))
            (revokeWorkerSession (workerLoginSession login))
        )
    absent <-
      tryAny
        ( auditWorkerSessions
            auditOps
            serviceAccountUid
            (Just (workerLoginAccessor login))
        )
    let cleanup = workerCleanupResult absent
    acknowledged <- case (cleanup, provisionalEmitted) of
      (Right (), True) -> tryAny emitWorkerCleanupCompletion
      _ -> pure (Right (Right ()))
    case attempted of
      Left exception
        | isAsyncException exception -> throwIO exception
      _ -> case exchanged of
        Left exception
          | isAsyncException exception -> throwIO exception
        _ -> pure $ do
          cleanup
          either
            (const (Left TargetSecretWorkerCleanupAuthorizationUnavailable))
            id
            acknowledged
          outcome <- case attempted of
            Left _ -> Left TargetSecretWorkerUnhandledException
            Right value -> value
          case exchanged of
            Left _ -> Left TargetSecretWorkerCleanupAuthorizationUnavailable
            Right (Left err) -> Left err
            Right (Right ()) -> Right outcome

  workerCleanupResult absent = case absent of
    Right (Right ()) -> Right ()
    _ -> Left TargetSecretWorkerVaultSessionCleanupUnavailable

cleanupDominates
  :: TargetSecretWorkerRuntimeError
  -> Either SomeException (Either TargetSecretWorkerRuntimeError ())
  -> Either TargetSecretWorkerRuntimeError value
cleanupDominates original cleanup = case cleanup of
  Right (Right ()) -> Left original
  _ -> Left TargetSecretWorkerVaultSessionCleanupUnavailable

-- | Injectable recovery for an auditor role that drifted from the required
-- bounded batch-token semantics.  Every invalid returned bearer is revoked;
-- once an independently valid batch auditor is obtained, each server-issued
-- accessor is revoked and observed stably absent before the valid auditor can
-- be used for worker-session cleanup.
data TargetWorkerAuditorRecoveryBoundary m login = TargetWorkerAuditorRecoveryBoundary
  { acquireTargetWorkerAuditorLogin :: m (Either Text login)
  , targetWorkerAuditorLoginAccepted :: login -> Bool
  , targetWorkerAuditorLoginMayHaveAccessor :: login -> Bool
  , targetWorkerAuditorLoginAccessor :: login -> Text
  , revokeTargetWorkerAuditorLogin :: login -> m (Either Text ())
  , revokeTargetWorkerAuditorAccessor :: login -> Text -> m (Either Text ())
  , observeTargetWorkerAuditorAccessorAbsent :: login -> Text -> m (Either Text Bool)
  , waitTargetWorkerAuditorVisibility :: m ()
  }

acquireTargetWorkerAuditorWith
  :: (Monad m)
  => Int
  -> Int
  -> TargetWorkerAuditorRecoveryBoundary m login
  -> m (Either Text login)
acquireTargetWorkerAuditorWith maximumLogins maximumObservations boundary =
  seek maximumLogins [] False
 where
  seek remaining leakedAccessors unresolvedAccessor
    | remaining <= 0 = pure (Left "Target worker auditor evidence is unavailable")
    | otherwise = do
        acquired <- acquireTargetWorkerAuditorLogin boundary
        case acquired of
          Left _ -> seek (remaining - 1) leakedAccessors unresolvedAccessor
          Right login
            | targetWorkerAuditorLoginAccepted boundary login -> do
                cleaned <- closeLeakedAccessors login leakedAccessors
                pure $ case cleaned of
                  Left detail -> Left detail
                  Right ()
                    | unresolvedAccessor ->
                        Left "Target worker auditor accessor cannot be proven absent"
                    | otherwise -> Right login
            | otherwise -> do
                _ <- revokeTargetWorkerAuditorLogin boundary login
                let rawAccessor = targetWorkerAuditorLoginAccessor boundary login
                    canonicalAccessor = canonicalWorkerAccessor rawAccessor
                    mayHaveAccessor =
                      targetWorkerAuditorLoginMayHaveAccessor boundary login
                    nextAccessors = case canonicalAccessor of
                      Just accessor -> accessor : leakedAccessors
                      Nothing -> leakedAccessors
                    nextUnresolved =
                      unresolvedAccessor
                        || (mayHaveAccessor && canonicalAccessor == Nothing)
                seek (remaining - 1) nextAccessors nextUnresolved

  closeLeakedAccessors _ [] = pure (Right ())
  closeLeakedAccessors auditor (accessor : rest) = do
    _ <- revokeTargetWorkerAuditorAccessor boundary auditor accessor
    absent <- proveStableAccessorAbsence auditor accessor maximumObservations
    case absent of
      Left detail -> pure (Left detail)
      Right () -> closeLeakedAccessors auditor rest

  proveStableAccessorAbsence auditor accessor remaining
    | remaining <= 0 =
        pure (Left "Target worker auditor accessor absence is unobservable")
    | otherwise = do
        observed <- observeTargetWorkerAuditorAccessorAbsent boundary auditor accessor
        case observed of
          Right True -> do
            waitTargetWorkerAuditorVisibility boundary
            confirmed <- observeTargetWorkerAuditorAccessorAbsent boundary auditor accessor
            case confirmed of
              Right True -> pure (Right ())
              _ -> retryAbsence auditor accessor (remaining - 1)
          _ -> retryAbsence auditor accessor (remaining - 1)

  retryAbsence auditor accessor remaining = do
    waitTargetWorkerAuditorVisibility boundary
    proveStableAccessorAbsence auditor accessor remaining

canonicalWorkerAccessor :: Text -> Maybe Text
canonicalWorkerAccessor raw
  | Text.null raw = Nothing
  | Text.length raw > 512 = Nothing
  | Text.strip raw /= raw = Nothing
  | Text.any (\character -> isControl character || isSpace character) raw = Nothing
  | otherwise = Just raw

newWorkerAuditor
  :: Text -> IO (Either TargetSecretWorkerRuntimeError VaultKubernetesLoginResult)
newWorkerAuditor jwt = do
  acquired <-
    acquireTargetWorkerAuditorWith
      auditorRecoveryAttempts
      auditorAccessorObservationAttempts
      (productionTargetWorkerAuditorBoundary jwt)
  pure (first (const TargetSecretWorkerVaultSessionCleanupUnavailable) acquired)

productionTargetWorkerAuditorBoundary
  :: Text
  -> TargetWorkerAuditorRecoveryBoundary IO VaultKubernetesLoginResult
productionTargetWorkerAuditorBoundary jwt =
  TargetWorkerAuditorRecoveryBoundary
    { acquireTargetWorkerAuditorLogin =
        first (const "auditor login unavailable")
          <$> vaultKubernetesLoginWithLease
            workerVaultAddress
            workerVaultAuthPath
            targetSecretWorkerAuditorVaultRole
            jwt
    , targetWorkerAuditorLoginAccepted =
        isBoundedBatchAuditorLogin auditorMaximumLeaseSeconds
    , targetWorkerAuditorLoginMayHaveAccessor = \login ->
        vaultLoginTokenType login /= "batch"
          || not (Text.null (Text.strip (vaultLoginAccessor login)))
    , targetWorkerAuditorLoginAccessor = vaultLoginAccessor
    , revokeTargetWorkerAuditorLogin = \login ->
        first (const "auditor revoke unavailable")
          <$> vaultRevokeSelf workerVaultAddress (vaultLoginToken login)
    , revokeTargetWorkerAuditorAccessor = \auditor accessor ->
        first (const "auditor accessor revoke unavailable")
          <$> vaultRevokeTokenAccessor
            workerVaultAddress
            (vaultLoginToken auditor)
            accessor
    , observeTargetWorkerAuditorAccessorAbsent = \auditor accessor ->
        first (const "auditor accessor absence unavailable")
          <$> vaultTokenAccessorAbsent
            workerVaultAddress
            (vaultLoginToken auditor)
            accessor
    , waitTargetWorkerAuditorVisibility =
        threadDelay accessorVisibilityGraceMicros
    }

workerAccessorAuditOps
  :: VaultKubernetesLoginResult -> VaultAccessorAuditOps IO
workerAccessorAuditOps auditor =
  VaultAccessorAuditOps
    { auditListAccessors =
        fmap
          (first (const "accessor inventory unavailable") . fmap tokenAccessorKeys)
          (vaultListTokenAccessors workerVaultAddress auditorToken)
    , auditLookupAccessor = \accessor ->
        classifyVaultAccessorLookupResponse
          <$> vaultLookupTokenAccessorInfo workerVaultAddress auditorToken accessor
    , auditRevokeAccessor = \accessor ->
        first (const "accessor revocation unavailable")
          <$> vaultRevokeTokenAccessor workerVaultAddress auditorToken accessor
    , auditObserveAccessorAbsent = \accessor ->
        first (const "accessor absence unavailable")
          <$> vaultTokenAccessorAbsent workerVaultAddress auditorToken accessor
    , auditWaitVisibilityGrace =
        threadDelay accessorVisibilityGraceMicros >> pure (Right ())
    }
 where
  auditorToken = vaultLoginToken auditor

workerAccessorSubject :: TargetWorkerServiceAccountUid -> VaultAccessorSubject
workerAccessorSubject serviceAccountUid =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["default", targetSecretWorkerVaultRole]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", targetSecretWorkerVaultRole)
          , ("service_account_name", targetSecretWorkerVaultRole)
          , ("service_account_namespace", workerNamespace)
          , ("service_account_uid", targetWorkerServiceAccountUidText serviceAccountUid)
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

auditWorkerSessions
  :: VaultAccessorAuditOps IO
  -> TargetWorkerServiceAccountUid
  -> Maybe Text
  -> IO (Either TargetSecretWorkerRuntimeError ())
auditWorkerSessions auditOps serviceAccountUid maybeKnown =
  fmap (first (const TargetSecretWorkerVaultSessionCleanupUnavailable)) $
    revokeAndProveVaultAccessorSubjectAbsent
      auditOps
      (workerAccessorSubject serviceAccountUid)
      maybeKnown

materializationReceipt
  :: TargetWorkerMaterializationResult -> TargetWorkerReceipt
materializationReceipt materialized = case materialized of
  TargetWorkerMaterializationApplied receipt -> receipt
  TargetWorkerMaterializationAlreadyApplied receipt -> receipt
  TargetWorkerMaterializationRecovered receipt -> receipt

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe AsyncException)

revokeWorkerSession
  :: VaultSession -> IO (Either TargetWorkerExecutionError ())
revokeWorkerSession session = do
  tokenResult <- sessionToken session
  case tokenResult of
    Left _ -> pure (Left TargetWorkerExecutionSessionRevocationFailed)
    Right token -> do
      revoked <- vaultRevokeSelf (sessionAddress session) token
      pure $ case revoked of
        Left _ -> Left TargetWorkerExecutionSessionRevocationFailed
        Right () -> Right ()

workerVaultAddress :: VaultAddress
workerVaultAddress = VaultAddress "http://vault.vault.svc.cluster.local:8200"

workerVaultAuthPath :: Text
workerVaultAuthPath = "kubernetes"

workerNamespace :: Text
workerNamespace = "target-secret-agent"

workerMaximumLeaseSeconds :: Int
workerMaximumLeaseSeconds = 600

auditorMaximumLeaseSeconds :: Int
auditorMaximumLeaseSeconds = 300

auditorRecoveryAttempts :: Int
auditorRecoveryAttempts = 4

auditorAccessorObservationAttempts :: Int
auditorAccessorObservationAttempts = 8

-- Vault auth/token writes become visible through the accessor inventory on a
-- separate storage read.  This bounded grace is part of the terminal protocol,
-- not a retry backoff.
accessorVisibilityGraceMicros :: Int
accessorVisibilityGraceMicros = 1000000

currentTime :: IO (Either TargetSecretWorkerRuntimeError AuthorityTime)
currentTime = do
  attempted <- try getPOSIXTime :: IO (Either IOException POSIXTime)
  pure $ case attempted of
    Left _ -> Left TargetSecretWorkerClockUnavailable
    Right value
      | value < 0 -> Left TargetSecretWorkerClockUnavailable
      | otherwise ->
          Right (authorityTimeFromMicros (fromInteger (floor (value * 1000000))))

readTargetWorkerPodUid
  :: FilePath -> IO (Either TargetSecretWorkerRuntimeError TargetWorkerPodUid)
readTargetWorkerPodUid path = do
  attempted <-
    readWorkerProjectedText (targetWorkerKubernetesUidMaximumCharacters + lineEndingCharacters) path
  pure $ case attempted of
    Left WorkerProjectedFileTooLarge -> Left TargetSecretWorkerPodUidInvalid
    Left _ -> Left TargetSecretWorkerPodUidReadFailed
    Right raw ->
      first (const TargetSecretWorkerPodUidInvalid) (mkTargetWorkerPodUid (Text.strip raw))

readTargetWorkerPodName :: FilePath -> IO (Either TargetSecretWorkerRuntimeError Text)
readTargetWorkerPodName path = do
  attempted <- readWorkerProjectedText (workerPodNameMaximumCharacters + lineEndingCharacters) path
  pure $ case attempted of
    Left WorkerProjectedFileTooLarge -> Left TargetSecretWorkerPodNameInvalid
    Left _ -> Left TargetSecretWorkerPodNameReadFailed
    Right raw
      | Text.null value || Text.length value > workerPodNameMaximumCharacters ->
          Left TargetSecretWorkerPodNameInvalid
      | Text.any (\character -> character <= ' ' || isControl character) value ->
          Left TargetSecretWorkerPodNameInvalid
      | otherwise -> Right value
     where
      value = Text.strip raw

readTargetWorkerProjectedToken :: FilePath -> IO (Either String Text)
readTargetWorkerProjectedToken path = do
  attempted <- readWorkerProjectedText workerProjectedTokenMaximumCharacters path
  pure $ case attempted of
    Left WorkerProjectedFileTooLarge -> Left "projected token is too large"
    Left WorkerProjectedFileInvalidUtf8 -> Left "projected token is not valid UTF-8"
    Left WorkerProjectedFileNotRegular -> Left "projected token path is not a regular file"
    Left WorkerProjectedFileUnavailable -> Left "projected token file is unavailable"
    Right raw
      | Text.null (Text.strip raw) -> Left "projected token is empty"
      | otherwise -> Right (Text.strip raw)

data WorkerProjectedFileError
  = WorkerProjectedFileUnavailable
  | WorkerProjectedFileNotRegular
  | WorkerProjectedFileTooLarge
  | WorkerProjectedFileInvalidUtf8

workerProjectedTokenMaximumCharacters, workerPodNameMaximumCharacters, lineEndingCharacters :: Int
workerProjectedTokenMaximumCharacters = 32768
workerPodNameMaximumCharacters = 253
lineEndingCharacters = Text.length "\r\n"

-- Kubernetes projected files are regular files reached through symlinks.
-- Check the opened descriptor, not the path, and never wait on a FIFO. Four
-- bytes per Unicode character preserve the existing character-bound token.
readWorkerProjectedText :: Int -> FilePath -> IO (Either WorkerProjectedFileError Text)
readWorkerProjectedText maximumCharacters path = do
  attempted <-
    try
      ( bracket
          (openFd path ReadOnly (defaultFileFlags {nonBlock = True, cloexec = True}))
          closeFd
          readOpened
      )
      :: IO (Either IOException (Either WorkerProjectedFileError ByteString))
  pure $ do
    bytes <- either (const (Left WorkerProjectedFileUnavailable)) id attempted
    raw <- first (const WorkerProjectedFileInvalidUtf8) (TextEncoding.decodeUtf8' bytes)
    if Text.length raw > maximumCharacters
      then Left WorkerProjectedFileTooLarge
      else Right raw
 where
  maximumBytes = 4 * maximumCharacters
  readOpened fd = do
    status <- getFdStatus fd
    if not (isRegularFile status)
      then pure (Left WorkerProjectedFileNotRegular)
      else
        if fileSize status > fromIntegral maximumBytes
          then pure (Left WorkerProjectedFileTooLarge)
          else readWorkerProjectedBytes fd maximumBytes []

readWorkerProjectedBytes
  :: Fd -> Int -> [ByteString] -> IO (Either WorkerProjectedFileError ByteString)
readWorkerProjectedBytes fd remaining chunks = do
  attempted <- try (Posix.fdRead fd (fromIntegral (min 65536 (remaining + 1))))
  case attempted of
    Left err
      | isEOFError err -> pure (Right (ByteString.concat (reverse chunks)))
      | otherwise -> pure (Left WorkerProjectedFileUnavailable)
    Right bytes
      | ByteString.null bytes -> pure (Right (ByteString.concat (reverse chunks)))
      | ByteString.length bytes > remaining -> pure (Left WorkerProjectedFileTooLarge)
      | otherwise -> readWorkerProjectedBytes fd (remaining - ByteString.length bytes) (bytes : chunks)

stdioProvisionalBoundary
  :: TargetWorkerProvisionalCompletion
  -> IO (Either TargetSecretWorkerRuntimeError ())
stdioProvisionalBoundary completion = do
  let encoded = encodeTargetWorkerProvisionalCompletion completion
  if ByteString.length encoded > targetWorkerProvisionalCompletionMaximumBytes
    then pure (Left TargetSecretWorkerCleanupAuthorizationUnavailable)
    else do
      emitted <- writeFramedStdout encoded
      case emitted of
        Left err -> pure (Left err)
        Right () -> do
          authorization <- readFramedHandleBounded 128 stdin
          pure $ case authorization of
            Right value
              | value == targetWorkerCleanupAuthorization -> Right ()
            _ -> Left TargetSecretWorkerCleanupAuthorizationUnavailable

emitWorkerCleanupCompletion
  :: IO (Either TargetSecretWorkerRuntimeError ())
emitWorkerCleanupCompletion = writeFramedStdout targetWorkerCleanupCompletion

writeFramedStdout
  :: ByteString -> IO (Either TargetSecretWorkerRuntimeError ())
writeFramedStdout payload = do
  attempted <-
    try
      ( do
          ByteString.hPut stdout (workerFrameLengthPrefix (ByteString.length payload))
          ByteString.hPut stdout payload
          hFlush stdout
      )
      :: IO (Either IOException ())
  pure $ case attempted of
    Left _ -> Left TargetSecretWorkerCleanupAuthorizationUnavailable
    Right () -> Right ()

readFramedHandleBounded
  :: Int -> Handle -> IO (Either TargetSecretWorkerRuntimeError ByteString)
readFramedHandleBounded maximumBytes handle = do
  prefixResult <- readExactHandle 4 handle
  case prefixResult of
    Left err -> pure (Left err)
    Right prefix -> do
      let declaredLength = decodeWorkerFrameLengthPrefix prefix
      if declaredLength > maximumBytes
        then
          pure
            ( Left
                (TargetSecretWorkerStdinTooLarge declaredLength maximumBytes)
            )
        else readExactHandle declaredLength handle

readExactHandle
  :: Int -> Handle -> IO (Either TargetSecretWorkerRuntimeError ByteString)
readExactHandle expected handle = go expected []
 where
  go remaining chunks
    | remaining == 0 = pure (Right (ByteString.concat (reverse chunks)))
    | otherwise = do
        attempted <-
          try (ByteString.hGetSome handle (min 4096 remaining))
            :: IO (Either IOException ByteString)
        case attempted of
          Left _ -> pure (Left TargetSecretWorkerStdinReadFailed)
          Right chunk
            | ByteString.null chunk -> pure (Left TargetSecretWorkerStdinReadFailed)
            | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

workerFrameLengthPrefix :: Int -> ByteString
workerFrameLengthPrefix lengthValue =
  LazyByteString.toStrict
    (ByteStringBuilder.toLazyByteString (ByteStringBuilder.word32BE (fromIntegral lengthValue)))

decodeWorkerFrameLengthPrefix :: ByteString -> Int
decodeWorkerFrameLengthPrefix =
  ByteString.foldl' (\accumulator byte -> accumulator * 256 + fromIntegral byte) 0
