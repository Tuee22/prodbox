{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Runtime of the attested one-shot external-material Job.
--
-- The process reads exactly one bounded stdin frame, verifies the
-- Authority-signed permit against Vault Transit public metadata and its own
-- downward-API Pod UID, seals the EAB pair into the exact retained-home
-- custody lane, and always revokes its own Vault token.  Its role has no final
-- target or generic Vault authority; delivery is performed later by a
-- separately attested Target materializer using a destination envelope.
module Prodbox.Lifecycle.CredentialProvisioner.ExternalMaterialWorker
  ( ExternalMaterialWorkerOptions (..)
  , ExternalMaterialWorkerError (..)
  , ExternalMaterialWorkerTerminalCause (..)
  , ExternalMaterialWorkerTerminalLineDisposition (..)
  , classifyExternalMaterialWorkerTerminalCapture
  , finishExternalMaterialWorkerSession
  , renderExternalMaterialWorkerTerminalCause
  , renderExternalMaterialWorkerTerminalLineDisposition
  , runExternalMaterialWorker
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, displayException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( externalMaterialIngressAuditorVaultRole
  , externalMaterialIngressVaultRole
  )
import Prodbox.ControlPlane.ClosedSession (finishClosedSession)
import Prodbox.ControlPlane.ProjectedServiceAccountIdentity
  ( decodeProjectedServiceAccountIdentity
  , projectedServiceAccountIdentityMatchesPodUid
  , projectedServiceAccountIdentityServiceAccountUid
  )
import Prodbox.ControlPlane.RetainedMaterialWorker
  ( RetainedCustodySealResult (..)
  , sealRetainedCustody
  )
import Prodbox.ControlPlane.RetainedMaterialWorkerVault
  ( retainedCustodyVaultBoundary
  )
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLifecycleError (..)
  , ServiceSessionLoginBoundary (..)
  , ServiceSessionSubjects (..)
  , allocateNextServiceSessionBinding
  , withFencedServiceSession
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretPayload (AcmeEabMaterial)
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  )
import Prodbox.ControlPlane.VaultServiceSessionJournal
  ( vaultServiceSessionJournalRepository
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedMaterialSchema (RetainedAcmeEabMaterial)
  , RetainedMaterialSource
  , RetainedSealIntent
  , SRetainedMaterialSchema (SRetainedAcmeEabMaterial)
  , mkRetainedMaterialRef
  , mkRetainedSealIntent
  , retainedMaterialRefText
  , retainedSourceCiphertextDigest
  , retainedSourceCommitmentRef
  , retainedSourceReceiptRef
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( OperatorMaterialIngressFrame
  , consumeExternalAcmeEabIngressFrame
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialTargetReceipt
  , SignedExternalAcmeEabPermit
  , encodeExternalMaterialTargetReceiptTextEnvelope
  , encodeSignedExternalAcmeEabPermit
  , externalMaterialJobPodUid
  , mkExternalMaterialTargetReceipt
  , signedExternalMaterialDeadline
  , signedExternalMaterialGeneration
  , signedExternalMaterialJobBinding
  , signedExternalMaterialPermitId
  , signedExternalMaterialRequestDigest
  , verifySignedExternalAcmeEabPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalMaterialWorkerProtocol
  ( ExternalMaterialWorkerIngressError
  , externalMaterialWorkerIngressMaximumBytes
  , withExternalMaterialWorkerIngress
  )
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerPodUid
  , credentialProvisionerPodUidText
  , mkCredentialProvisionerPodUid
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  , vaultAuthorityManifestSigner
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( ManifestPublicKey
  , manifestPublicKeyBytes
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)
import Prodbox.Vault.Client
  ( TokenAccessorListing (..)
  , VaultAddress (..)
  , VaultKubernetesLoginResult (..)
  , vaultKubernetesLoginWithLease
  , vaultListTokenAccessors
  , vaultLookupTokenAccessorInfo
  , vaultRevokeSelf
  , vaultRevokeTokenAccessor
  , vaultTokenAccessorAbsent
  )
import Prodbox.Vault.Session
  ( LoginLease (..)
  , VaultSession
  , newVaultSession
  , realSessionClock
  , sessionAddress
  , sessionToken
  )
import System.Exit (ExitCode (..))
import System.IO (Handle, stdin, stdout)

data ExternalMaterialWorkerOptions = ExternalMaterialWorkerOptions
  { externalMaterialWorkerPermitId :: !Text
  , externalMaterialWorkerRequestDigest :: !Text
  , externalMaterialWorkerDeadlineMicros :: !Natural
  , externalMaterialWorkerPodUidFile :: !FilePath
  , externalMaterialWorkerServiceAccountTokenFile :: !FilePath
  }
  deriving stock (Eq, Show)

data ExternalMaterialWorkerError
  = ExternalMaterialWorkerStdinReadFailed
  | ExternalMaterialWorkerStdinTooLarge !Int !Int
  | ExternalMaterialWorkerFrameRejected !ExternalMaterialWorkerIngressError
  | ExternalMaterialWorkerPodUidReadFailed
  | ExternalMaterialWorkerPodUidInvalid
  | ExternalMaterialWorkerPodUidMismatch
  | ExternalMaterialWorkerPermitMetadataMismatch
  | ExternalMaterialWorkerClockUnavailable
  | ExternalMaterialWorkerVaultLoginUnavailable
  | ExternalMaterialWorkerAuthorityKeyUnavailable
  | ExternalMaterialWorkerPermitRejected
  | ExternalMaterialWorkerCustodyHandoffUnavailable
  | ExternalMaterialWorkerSessionRevocationFailed
  | ExternalMaterialWorkerUnhandledException
  deriving stock (Eq, Show)

-- | Closed, value-free terminal causes safe to cross the worker/log boundary.
-- The detailed internal error algebra is deliberately collapsed here: no
-- input sizes, nested wire values, provider bodies, or Vault data are emitted.
data ExternalMaterialWorkerTerminalCause
  = ExternalMaterialWorkerTerminalStdinReadFailed
  | ExternalMaterialWorkerTerminalStdinTooLarge
  | ExternalMaterialWorkerTerminalFrameRejected
  | ExternalMaterialWorkerTerminalPodUidReadFailed
  | ExternalMaterialWorkerTerminalPodUidInvalid
  | ExternalMaterialWorkerTerminalPodUidMismatch
  | ExternalMaterialWorkerTerminalPermitMetadataMismatch
  | ExternalMaterialWorkerTerminalClockUnavailable
  | ExternalMaterialWorkerTerminalVaultLoginUnavailable
  | ExternalMaterialWorkerTerminalAuthorityKeyUnavailable
  | ExternalMaterialWorkerTerminalPermitRejected
  | ExternalMaterialWorkerTerminalCustodyHandoffUnavailable
  | ExternalMaterialWorkerTerminalSessionRevocationFailed
  | ExternalMaterialWorkerTerminalUnhandledException
  deriving stock (Eq, Show, Enum, Bounded)

data ExternalMaterialWorkerTerminalLineDisposition
  = ExternalMaterialWorkerTerminalLineNone
  | ExternalMaterialWorkerTerminalLineUnique !ExternalMaterialWorkerTerminalCause
  | ExternalMaterialWorkerTerminalLineUnrecognized
  | ExternalMaterialWorkerTerminalLinesAmbiguous
  deriving stock (Eq, Show)

runExternalMaterialWorker :: ExternalMaterialWorkerOptions -> IO ExitCode
runExternalMaterialWorker options = do
  result <- runWorker options
  case result of
    Left err -> do
      writeDiagnosticLine
        ( Text.unpack externalMaterialWorkerTerminalLinePrefixText
            <> Text.unpack
              (renderExternalMaterialWorkerTerminalCause (workerTerminalCause err))
        )
      pure (ExitFailure 1)
    Right receipt -> do
      ByteString.hPut stdout ("\n" <> encodeExternalMaterialTargetReceiptTextEnvelope receipt)
      pure ExitSuccess

renderExternalMaterialWorkerTerminalCause
  :: ExternalMaterialWorkerTerminalCause -> Text
renderExternalMaterialWorkerTerminalCause cause = case cause of
  ExternalMaterialWorkerTerminalStdinReadFailed -> "stdin-read-failed"
  ExternalMaterialWorkerTerminalStdinTooLarge -> "stdin-too-large"
  ExternalMaterialWorkerTerminalFrameRejected -> "frame-rejected"
  ExternalMaterialWorkerTerminalPodUidReadFailed -> "pod-uid-read-failed"
  ExternalMaterialWorkerTerminalPodUidInvalid -> "pod-uid-invalid"
  ExternalMaterialWorkerTerminalPodUidMismatch -> "pod-uid-mismatch"
  ExternalMaterialWorkerTerminalPermitMetadataMismatch -> "permit-metadata-mismatch"
  ExternalMaterialWorkerTerminalClockUnavailable -> "clock-unavailable"
  ExternalMaterialWorkerTerminalVaultLoginUnavailable -> "vault-login-unavailable"
  ExternalMaterialWorkerTerminalAuthorityKeyUnavailable -> "authority-key-unavailable"
  ExternalMaterialWorkerTerminalPermitRejected -> "permit-rejected"
  ExternalMaterialWorkerTerminalCustodyHandoffUnavailable -> "custody-handoff-unavailable"
  ExternalMaterialWorkerTerminalSessionRevocationFailed -> "session-revocation-failed"
  ExternalMaterialWorkerTerminalUnhandledException -> "unhandled-exception"

renderExternalMaterialWorkerTerminalLineDisposition
  :: ExternalMaterialWorkerTerminalLineDisposition -> Text
renderExternalMaterialWorkerTerminalLineDisposition disposition = case disposition of
  ExternalMaterialWorkerTerminalLineNone -> "none"
  ExternalMaterialWorkerTerminalLineUnique cause ->
    renderExternalMaterialWorkerTerminalCause cause
  ExternalMaterialWorkerTerminalLineUnrecognized -> "unrecognized"
  ExternalMaterialWorkerTerminalLinesAmbiguous -> "ambiguous"

-- | Classify only exact whole terminal lines. A prefixed future value or more
-- than one prefixed line is retained as a closed refusal, never echoed.
classifyExternalMaterialWorkerTerminalCapture
  :: ByteString -> ExternalMaterialWorkerTerminalLineDisposition
classifyExternalMaterialWorkerTerminalCapture captured =
  case prefixedLines of
    [] -> ExternalMaterialWorkerTerminalLineNone
    [renderedCause] ->
      maybe
        ExternalMaterialWorkerTerminalLineUnrecognized
        ExternalMaterialWorkerTerminalLineUnique
        (decodeTerminalLine renderedCause)
    _ -> ExternalMaterialWorkerTerminalLinesAmbiguous
 where
  prefixedLines =
    mapMaybe
      (ByteString.stripPrefix externalMaterialWorkerTerminalLinePrefix)
      (ByteString.split 10 captured)
  decodeTerminalLine renderedCause =
    case [ cause
         | cause <- [minBound .. maxBound]
         , TextEncoding.encodeUtf8 (renderExternalMaterialWorkerTerminalCause cause)
             == renderedCause
         ] of
      [cause] -> Just cause
      _ -> Nothing

workerTerminalCause
  :: ExternalMaterialWorkerError -> ExternalMaterialWorkerTerminalCause
workerTerminalCause err = case err of
  ExternalMaterialWorkerStdinReadFailed -> ExternalMaterialWorkerTerminalStdinReadFailed
  ExternalMaterialWorkerStdinTooLarge _ _ -> ExternalMaterialWorkerTerminalStdinTooLarge
  ExternalMaterialWorkerFrameRejected _ -> ExternalMaterialWorkerTerminalFrameRejected
  ExternalMaterialWorkerPodUidReadFailed -> ExternalMaterialWorkerTerminalPodUidReadFailed
  ExternalMaterialWorkerPodUidInvalid -> ExternalMaterialWorkerTerminalPodUidInvalid
  ExternalMaterialWorkerPodUidMismatch -> ExternalMaterialWorkerTerminalPodUidMismatch
  ExternalMaterialWorkerPermitMetadataMismatch ->
    ExternalMaterialWorkerTerminalPermitMetadataMismatch
  ExternalMaterialWorkerClockUnavailable -> ExternalMaterialWorkerTerminalClockUnavailable
  ExternalMaterialWorkerVaultLoginUnavailable ->
    ExternalMaterialWorkerTerminalVaultLoginUnavailable
  ExternalMaterialWorkerAuthorityKeyUnavailable ->
    ExternalMaterialWorkerTerminalAuthorityKeyUnavailable
  ExternalMaterialWorkerPermitRejected -> ExternalMaterialWorkerTerminalPermitRejected
  ExternalMaterialWorkerCustodyHandoffUnavailable ->
    ExternalMaterialWorkerTerminalCustodyHandoffUnavailable
  ExternalMaterialWorkerSessionRevocationFailed ->
    ExternalMaterialWorkerTerminalSessionRevocationFailed
  ExternalMaterialWorkerUnhandledException -> ExternalMaterialWorkerTerminalUnhandledException

externalMaterialWorkerTerminalLinePrefixText :: Text
externalMaterialWorkerTerminalLinePrefixText = "external-material worker refused: "

externalMaterialWorkerTerminalLinePrefix :: ByteString
externalMaterialWorkerTerminalLinePrefix =
  TextEncoding.encodeUtf8 externalMaterialWorkerTerminalLinePrefixText

runWorker
  :: ExternalMaterialWorkerOptions
  -> IO (Either ExternalMaterialWorkerError ExternalMaterialTargetReceipt)
runWorker options = do
  stdinResult <- readHandleBounded externalMaterialWorkerIngressMaximumBytes stdin
  podUidResult <- readPodUid (externalMaterialWorkerPodUidFile options)
  case (stdinResult, podUidResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right input, Right actualPodUid) ->
      case withExternalMaterialWorkerIngress input (execute actualPodUid) of
        Left err -> pure (Left (ExternalMaterialWorkerFrameRejected err))
        Right effect -> effect
 where
  execute
    :: CredentialProvisionerPodUid
    -> CredentialProvisionerPodUid
    -> SignedExternalAcmeEabPermit
    -> OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
    -> IO (Either ExternalMaterialWorkerError ExternalMaterialTargetReceipt)
  execute actualPodUid framedPodUid permit frame
    | actualPodUid /= framedPodUid =
        pure (Left ExternalMaterialWorkerPodUidMismatch)
    | externalMaterialJobPodUid (signedExternalMaterialJobBinding permit)
        /= credentialProvisionerPodUidText actualPodUid =
        pure (Left ExternalMaterialWorkerPodUidMismatch)
    | operatorMaterialPermitIdText (signedExternalMaterialPermitId permit)
        /= externalMaterialWorkerPermitId options =
        pure (Left ExternalMaterialWorkerPermitMetadataMismatch)
    | targetValueDigestText (signedExternalMaterialRequestDigest permit)
        /= externalMaterialWorkerRequestDigest options =
        pure (Left ExternalMaterialWorkerPermitMetadataMismatch)
    | authorityTimeMicros (signedExternalMaterialDeadline permit)
        /= externalMaterialWorkerDeadlineMicros options =
        pure (Left ExternalMaterialWorkerPermitMetadataMismatch)
    | otherwise = do
        nowResult <- currentTime
        case nowResult of
          Left err -> pure (Left err)
          Right now -> do
            withWorkerVaultSession
              options
              actualPodUid
              permit
              ( \session ->
                  executeAuthenticated
                    session
                    now
                    permit
                    frame
              )

-- | The session cleanup combinator is intentionally outside the success path:
-- public-key, permit, CAS, and read-back refusals all run the same revoke-self
-- effect.  A failed revocation overrides every outcome and suppresses receipts.
finishExternalMaterialWorkerSession
  :: IO (Either ExternalMaterialWorkerError value)
  -> IO (Either ExternalMaterialWorkerError ())
  -> IO (Either ExternalMaterialWorkerError Bool)
  -> IO (Either ExternalMaterialWorkerError value)
finishExternalMaterialWorkerSession =
  finishClosedSession
    ExternalMaterialWorkerUnhandledException
    ExternalMaterialWorkerSessionRevocationFailed

executeAuthenticated
  :: VaultSession
  -> AuthorityTime
  -> SignedExternalAcmeEabPermit
  -> OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
  -> IO (Either ExternalMaterialWorkerError ExternalMaterialTargetReceipt)
executeAuthenticated session now permit frame = do
  publicResult <-
    readAuthorityManifestPublicKey (vaultAuthorityManifestSigner session)
  case publicResult of
    Left _ -> pure (Left ExternalMaterialWorkerAuthorityKeyUnavailable)
    Right (_, publicKey) ->
      case verifyPermit publicKey now permit of
        Left err -> pure (Left err)
        Right () ->
          consumeExternalAcmeEabIngressFrame frame $ \keyId hmacKey ->
            sealExternalEabCustody session now permit keyId hmacKey

sealExternalEabCustody
  :: VaultSession
  -> AuthorityTime
  -> SignedExternalAcmeEabPermit
  -> Text
  -> Text
  -> IO (Either ExternalMaterialWorkerError ExternalMaterialTargetReceipt)
sealExternalEabCustody session now permit keyId hmacKey =
  case retainedSealIntentForPermit permit of
    Left _ -> pure (Left ExternalMaterialWorkerCustodyHandoffUnavailable)
    Right intent -> do
      sealed <-
        sealRetainedCustody
          SRetainedAcmeEabMaterial
          now
          (retainedCustodyVaultBoundary session SRetainedAcmeEabMaterial)
          intent
          (AcmeEabMaterial keyId hmacKey)
      pure $ do
        result <-
          either
            (const (Left ExternalMaterialWorkerCustodyHandoffUnavailable))
            Right
            sealed
        let source = sealedSource result
        either
          (const (Left ExternalMaterialWorkerCustodyHandoffUnavailable))
          Right
          ( mkExternalMaterialTargetReceipt
              permit
              (retainedMaterialRefText (retainedSourceReceiptRef source))
              (retainedMaterialRefText (retainedSourceCommitmentRef source))
              (targetValueDigestText (retainedSourceCiphertextDigest source))
              (retainedSourceVaultVersion source)
          )

retainedSealIntentForPermit
  :: SignedExternalAcmeEabPermit
  -> Either Text (RetainedSealIntent 'RetainedAcmeEabMaterial)
retainedSealIntentForPermit permit = do
  reference <-
    mkRetainedMaterialRef
      (operatorMaterialPermitIdText (signedExternalMaterialPermitId permit))
  mkRetainedSealIntent
    reference
    (signedExternalMaterialGeneration permit)
    reference
    (signedExternalMaterialRequestDigest permit)
    (signedExternalMaterialDeadline permit)
    (signedExternalMaterialDeadline permit)

sealedSource
  :: RetainedCustodySealResult schema -> RetainedMaterialSource schema
sealedSource result = case result of
  RetainedCustodySealed source -> source
  RetainedCustodyAlreadySealed source -> source
  RetainedCustodySealRecovered source -> source

revokeWorkerSession :: VaultSession -> IO (Either ExternalMaterialWorkerError ())
revokeWorkerSession session = do
  tokenResult <- sessionToken session
  case tokenResult of
    Left _ -> pure (Left ExternalMaterialWorkerSessionRevocationFailed)
    Right token -> do
      revoked <- vaultRevokeSelf (sessionAddress session) token
      pure $ case revoked of
        Left _ -> Left ExternalMaterialWorkerSessionRevocationFailed
        Right () -> Right ()

verifyPermit
  :: ManifestPublicKey
  -> AuthorityTime
  -> SignedExternalAcmeEabPermit
  -> Either ExternalMaterialWorkerError ()
verifyPermit publicKey now permit =
  either
    (const (Left ExternalMaterialWorkerPermitRejected))
    Right
    (verifySignedExternalAcmeEabPermit (manifestPublicKeyBytes publicKey) now permit)

data WorkerVaultLogin = WorkerVaultLogin
  { workerLoginSession :: !VaultSession
  , workerLoginAccessor :: !Text
  }

withWorkerVaultSession
  :: ExternalMaterialWorkerOptions
  -> CredentialProvisionerPodUid
  -> SignedExternalAcmeEabPermit
  -> (VaultSession -> IO (Either ExternalMaterialWorkerError value))
  -> IO (Either ExternalMaterialWorkerError value)
withWorkerVaultSession options actualPodUid permit action = do
  jwtResult <- readProjectedToken (externalMaterialWorkerServiceAccountTokenFile options)
  case jwtResult of
    Left _ -> pure (Left ExternalMaterialWorkerVaultLoginUnavailable)
    Right jwt -> case decodeProjectedServiceAccountIdentity jwt of
      Left _ -> pure (Left ExternalMaterialWorkerPodUidMismatch)
      Right identity
        | not
            ( projectedServiceAccountIdentityMatchesPodUid
                externalMaterialWorkerNamespace
                (credentialProvisionerPodUidText actualPodUid)
                externalMaterialIngressVaultRole
                identity
            ) ->
            pure (Left ExternalMaterialWorkerPodUidMismatch)
        | otherwise -> do
            auditorResult <- newWorkerAuditor jwt
            case auditorResult of
              Left err -> pure (Left err)
              Right auditor -> do
                let repository =
                      vaultServiceSessionJournalRepository
                        workerVaultAddress
                        (vaultLoginToken auditor)
                        externalMaterialIngressVaultRole
                    serviceAccountUid =
                      projectedServiceAccountIdentityServiceAccountUid identity
                allocated <-
                  allocateNextServiceSessionBinding
                    repository
                    externalMaterialIngressVaultRole
                    (operatorMaterialPermitIdText (signedExternalMaterialPermitId permit))
                    (workerAttemptId permit)
                case allocated of
                  Left _ -> pure (Left ExternalMaterialWorkerSessionRevocationFailed)
                  Right sessionBinding -> do
                    actionError <- newIORef Nothing
                    result <-
                      withFencedServiceSession
                        repository
                        (workerAccessorAuditOps auditor)
                        (workerSessionSubjects serviceAccountUid)
                        sessionBinding
                        (workerLoginBoundary jwt)
                        (runAction actionError)
                    case result of
                      Right value -> pure (Right value)
                      Left lifecycleError -> do
                        original <- readIORef actionError
                        pure (Left (mapLifecycleError original lifecycleError))
 where
  runAction actionError login = do
    result <- action (workerLoginSession login)
    case result of
      Left err -> do
        writeIORef actionError (Just err)
        pure (Left "external material execution refused")
      Right value -> pure (Right value)

newWorkerVaultSession
  :: Text -> IO (Either ExternalMaterialWorkerError WorkerVaultLogin)
newWorkerVaultSession jwt = do
  result <-
    vaultKubernetesLoginWithLease
      workerVaultAddress
      workerVaultAuthPath
      externalMaterialIngressVaultRole
      jwt
  case result of
    Left _ -> pure (Left ExternalMaterialWorkerVaultLoginUnavailable)
    Right login
      | not (validWorkerLogin login) -> do
          _ <- vaultRevokeSelf workerVaultAddress (vaultLoginToken login)
          pure (Left ExternalMaterialWorkerVaultLoginUnavailable)
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
                  , workerLoginAccessor = vaultLoginAccessor login
                  }
            )

validWorkerLogin :: VaultKubernetesLoginResult -> Bool
validWorkerLogin login =
  vaultLoginTokenType login == "service"
    && not (Text.null (vaultLoginAccessor login))
    && vaultLoginAccessor login == Text.strip (vaultLoginAccessor login)
    && vaultLoginLeaseSeconds login > 0
    && vaultLoginLeaseSeconds login <= workerMaximumLeaseSeconds

newWorkerAuditor
  :: Text -> IO (Either ExternalMaterialWorkerError VaultKubernetesLoginResult)
newWorkerAuditor jwt = do
  loggedIn <-
    vaultKubernetesLoginWithLease
      workerVaultAddress
      workerVaultAuthPath
      externalMaterialIngressAuditorVaultRole
      jwt
  pure $ case loggedIn of
    Left _ -> Left ExternalMaterialWorkerSessionRevocationFailed
    Right auditor
      | isBoundedBatchAuditorLogin workerAuditorMaximumLeaseSeconds auditor ->
          Right auditor
      | otherwise -> Left ExternalMaterialWorkerSessionRevocationFailed

workerLoginBoundary :: Text -> ServiceSessionLoginBoundary WorkerVaultLogin
workerLoginBoundary jwt =
  ServiceSessionLoginBoundary
    { attemptServiceSessionLogin =
        first (Text.pack . show) <$> newWorkerVaultSession jwt
    , serviceSessionLoginAccessor = workerLoginAccessor
    , revokeServiceSessionLogin = \login ->
        first (Text.pack . show) <$> revokeWorkerSession (workerLoginSession login)
    }

workerAccessorAuditOps
  :: VaultKubernetesLoginResult -> VaultAccessorAuditOps IO
workerAccessorAuditOps auditor =
  VaultAccessorAuditOps
    { auditListAccessors =
        first (const "accessor inventory unavailable")
          . fmap tokenAccessorKeys
          <$> vaultListTokenAccessors workerVaultAddress token
    , auditLookupAccessor = \accessor ->
        first (const "accessor classification unavailable")
          <$> vaultLookupTokenAccessorInfo workerVaultAddress token accessor
    , auditRevokeAccessor = \accessor ->
        first (const "accessor revocation unavailable")
          <$> vaultRevokeTokenAccessor workerVaultAddress token accessor
    , auditObserveAccessorAbsent = \accessor ->
        first (const "accessor absence unavailable")
          <$> vaultTokenAccessorAbsent workerVaultAddress token accessor
    , auditWaitVisibilityGrace =
        threadDelay workerAccessorVisibilityGraceMicros >> pure (Right ())
    }
 where
  token = vaultLoginToken auditor

workerSessionSubjects :: Text -> ServiceSessionSubjects
workerSessionSubjects serviceAccountUid =
  ServiceSessionSubjects
    { serviceSessionCleanupSubject = subject Nothing
    , serviceSessionActiveSubject = subject (Just serviceAccountUid)
    }
 where
  subject maybeUid =
    VaultAccessorSubject
      { vaultAccessorSubjectPolicies = ["default", externalMaterialIngressVaultRole]
      , vaultAccessorSubjectMetadata =
          Map.fromList
            ( [ ("role", externalMaterialIngressVaultRole)
              , ("service_account_name", externalMaterialIngressVaultRole)
              , ("service_account_namespace", externalMaterialWorkerNamespace)
              ]
                <> maybe [] (\uid -> [("service_account_uid", uid)]) maybeUid
            )
      , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
      }

mapLifecycleError
  :: Maybe ExternalMaterialWorkerError
  -> ServiceSessionLifecycleError
  -> ExternalMaterialWorkerError
mapLifecycleError original lifecycleError = case lifecycleError of
  ServiceSessionLifecycleActionFailed _ ->
    maybe ExternalMaterialWorkerUnhandledException id original
  ServiceSessionLifecycleLoginFailedCleaned _ ->
    ExternalMaterialWorkerVaultLoginUnavailable
  ServiceSessionLifecycleAccessorInvalid ->
    ExternalMaterialWorkerVaultLoginUnavailable
  ServiceSessionLifecycleAccessorIdentityMismatch ->
    ExternalMaterialWorkerVaultLoginUnavailable
  ServiceSessionLifecycleUnhandledException ->
    maybe ExternalMaterialWorkerUnhandledException id original
  _ -> ExternalMaterialWorkerSessionRevocationFailed

workerAttemptId :: SignedExternalAcmeEabPermit -> Text
workerAttemptId permit =
  "permit-" <> sha256Text (encodeSignedExternalAcmeEabPermit permit)

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

workerVaultAddress :: VaultAddress
workerVaultAddress = VaultAddress "http://vault.vault.svc.cluster.local:8200"

workerVaultAuthPath :: Text
workerVaultAuthPath = "kubernetes"

externalMaterialWorkerNamespace :: Text
externalMaterialWorkerNamespace = "credential-provisioner"

workerMaximumLeaseSeconds :: Int
workerMaximumLeaseSeconds = 600

workerAuditorMaximumLeaseSeconds :: Int
workerAuditorMaximumLeaseSeconds = 120

workerAccessorVisibilityGraceMicros :: Int
workerAccessorVisibilityGraceMicros = 1000000

currentTime :: IO (Either ExternalMaterialWorkerError AuthorityTime)
currentTime = do
  attempted <- try getPOSIXTime :: IO (Either IOException POSIXTime)
  pure $ case attempted of
    Left _ -> Left ExternalMaterialWorkerClockUnavailable
    Right value
      | value < 0 -> Left ExternalMaterialWorkerClockUnavailable
      | otherwise ->
          Right (authorityTimeFromMicros (fromInteger (floor (value * 1000000))))

readPodUid
  :: FilePath
  -> IO (Either ExternalMaterialWorkerError CredentialProvisionerPodUid)
readPodUid path = do
  attempted <- try (TextIO.readFile path) :: IO (Either IOException Text)
  pure $ case attempted of
    Left _ -> Left ExternalMaterialWorkerPodUidReadFailed
    Right raw ->
      either
        (const (Left ExternalMaterialWorkerPodUidInvalid))
        Right
        (mkCredentialProvisionerPodUid (Text.strip raw))

readProjectedToken :: FilePath -> IO (Either String Text)
readProjectedToken path = do
  attempted <- try (TextIO.readFile path) :: IO (Either IOException Text)
  pure $ case attempted of
    Left err -> Left (displayException err)
    Right raw
      | Text.null (Text.strip raw) -> Left "projected token is empty"
      | Text.length raw > 32768 -> Left "projected token is too large"
      | otherwise -> Right (Text.strip raw)

readHandleBounded
  :: Int -> Handle -> IO (Either ExternalMaterialWorkerError ByteString)
readHandleBounded maximumBytes handle = go ByteString.empty
 where
  go accumulated = do
    attempted <- try (ByteString.hGetSome handle 4096) :: IO (Either IOException ByteString)
    case attempted of
      Left _ -> pure (Left ExternalMaterialWorkerStdinReadFailed)
      Right chunk
        | ByteString.null chunk -> pure (Right accumulated)
        | ByteString.length accumulated + ByteString.length chunk > maximumBytes ->
            pure
              ( Left
                  ( ExternalMaterialWorkerStdinTooLarge
                      (ByteString.length accumulated + ByteString.length chunk)
                      maximumBytes
                  )
              )
        | otherwise -> go (accumulated <> chunk)
