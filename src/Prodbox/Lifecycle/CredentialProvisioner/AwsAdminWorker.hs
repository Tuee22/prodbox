{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Runtime boundary for the attested one-shot AWS-admin Credential
-- Provisioner. Administrator credentials exist only inside the bounded stdin
-- continuation. The worker verifies the exact signed mode/argv/Pod/Service
-- Account identity, executes through the durable IAM journal, proves its
-- accessor-bearing Vault session absent, and only then uses a fresh
-- accessor-free batch identity for the terminal Authority receipt.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminWorker
  ( AwsAdminWorkerMode (..)
  , awsAdminWorkerModeToken
  , AwsAdminWorkerOptions (..)
  , AwsAdminWorkerError (..)
  , runAwsAdminWorker
  , runAwsAdminWorkerWith
  , finishAwsAdminWorkerSession
  , awsAdminTargetWorkerMaximumRuntimeSeconds
  , awsAdminAuthorityHttpConfig
  , awsAdminRetainedDeliveryHttpConfig
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, displayException, try)
import Control.Monad (void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isControl, isSpace)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.Capacity.RetainedMaterialDeliveryBudget qualified as RetainedMaterialDeliveryBudget
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  , credentialProvisionerAuditorMaximumLeaseSeconds
  , credentialProvisionerAuditorVaultRole
  , credentialProvisionerCompletionVaultRole
  , credentialProvisionerVaultRole
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( awsAdminProvisionerClient
  , completeAwsAdminProvisioning
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( awsAdminProvisionerResponseMaximumBytes
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
      ( CallerCredentialProvisioner
      , CallerCredentialProvisionerCompletion
      )
  )
import Prodbox.ControlPlane.Client
  ( mkLifecycleAuthorityEndpoint
  , mkTargetSecretAgentEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.ClosedSession (finishClosedSession)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.ListenPort (controlPlaneClusterServiceUrlText)
import Prodbox.ControlPlane.ProjectedServiceAccountIdentity
  ( decodeProjectedServiceAccountIdentity
  , projectedServiceAccountIdentityMatches
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( readRetainedAuthorityEpoch
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryClient
  ( requestRetainedMaterialDelivery
  , retainedMaterialDeliveryClient
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( retainedMaterialDeliveryWireRequest
  )
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLifecycleError (..)
  , ServiceSessionLoginBoundary (..)
  , ServiceSessionSubjects (..)
  , allocateNextServiceSessionBinding
  , withFencedServiceSession
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( targetIntentAuthorityClient
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( targetMaterialClient
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( targetMaterialResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetMaterializationProduction
  ( productionAwsAdminDeliveryBoundary
  , productionTargetMaterializationBoundary
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( targetAgentClusterIdentity
  )
import Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( TargetWorkerJobConnection (..)
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditError (..)
  , VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  , isExactBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  )
import Prodbox.ControlPlane.VaultServiceSessionJournal
  ( vaultServiceSessionJournalRepository
  )
import Prodbox.Http.Client (HttpConfig (..), defaultHttpConfig)
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedMaterialSchema (RetainedSesSmtpMaterial)
  , RetainedMaterialSource
  , SRetainedMaterialSchema (SRetainedSesSmtpMaterial)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminDeliveryBoundary
  , AwsAdminWorkerActionProgress (..)
  , AwsAdminWorkerExecutionCause (AwsAdminWorkerExecutionUnclassified)
  , AwsAdminWorkerReceipt
  , AwsAdminWorkerSessionClosureCause (..)
  , AwsAdminWorkerTerminalCause (..)
  , classifyAwsAdminExecutionError
  , classifyAwsAdminWorkerJournalUnavailable
  , encodeAwsAdminWorkerReceiptTextEnvelope
  , executeAwsAdminPermit
  , productionAwsAdminIamBoundary
  , renderAwsAdminWorkerTerminalCause
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionVault
  ( vaultAwsAdminExecutionJournalBoundary
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminCleanupRecoveryProgram (..)
  , AwsAdminPermitKind (..)
  , SignedAwsAdminPermit
  , awsAdminJobPodName
  , awsAdminJobPodUid
  , awsAdminJobServiceAccount
  , awsAdminJobServiceAccountUid
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentRequestDigest
  , credentialIamParametersProgram
  , encodeSignedAwsAdminPermit
  , signedAwsAdminPermitBinding
  , signedAwsAdminPermitIntent
  , signedAwsAdminPermitSignerGeneration
  , verifySignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminRetainedCustody
  ( productionRetainedCustodyAwsAdminDelivery
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminWorkerProtocol
  ( AwsAdminWorkerIngressError
  , awsAdminWorkerIngressMaximumBytes
  , withAwsAdminWorkerIngress
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
  ( openProductionIamSession
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  , vaultAuthorityManifestSigner
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( manifestPublicKeyBytes
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , targetValueDigestText
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime)
  )
import Prodbox.Settings (Credentials)
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

data AwsAdminWorkerMode
  = AwsAdminNormalMode
  | AwsAdminGenesisBackupMode
  | AwsAdminBackupRepairMode
  deriving stock (Eq, Show)

awsAdminWorkerModeToken :: AwsAdminWorkerMode -> Text
awsAdminWorkerModeToken mode = case mode of
  AwsAdminNormalMode -> "normal"
  AwsAdminGenesisBackupMode -> "genesis-backup"
  AwsAdminBackupRepairMode -> "backup-repair"

data AwsAdminWorkerOptions = AwsAdminWorkerOptions
  { awsAdminWorkerExpectedMode :: !AwsAdminWorkerMode
  , awsAdminWorkerExpectedOperationId :: !Text
  , awsAdminWorkerExpectedPermitId :: !Text
  , awsAdminWorkerExpectedRequestDigest :: !Text
  , awsAdminWorkerExpectedDeadlineMicros :: !Natural
  , awsAdminWorkerExpectedImageDigest :: !Text
  , awsAdminWorkerTargetImageRepository :: !Text
  , awsAdminWorkerExpectedAuthorityScope :: !Text
  , awsAdminWorkerExpectedAuthorityEndpoint :: !Text
  , awsAdminWorkerPodNameFile :: !FilePath
  , awsAdminWorkerPodUidFile :: !FilePath
  , awsAdminWorkerServiceAccountTokenFile :: !FilePath
  }
  deriving stock (Eq, Show)

data AwsAdminWorkerError
  = AwsAdminWorkerDeliveryCompositionUnavailable
  | AwsAdminWorkerStdinReadFailed
  | AwsAdminWorkerStdinTooLarge !Int !Int
  | AwsAdminWorkerFrameRejected !AwsAdminWorkerIngressError
  | AwsAdminWorkerPodIdentityReadFailed
  | AwsAdminWorkerPodIdentityInvalid
  | AwsAdminWorkerPodIdentityMismatch
  | AwsAdminWorkerPermitMetadataMismatch
  | AwsAdminWorkerModeMismatch
  | AwsAdminWorkerProjectedIdentityMismatch
  | AwsAdminWorkerClockUnavailable
  | AwsAdminWorkerVaultLoginUnavailable
  | AwsAdminWorkerAuthorityKeyUnavailable
  | AwsAdminWorkerPermitRejected
  | AwsAdminWorkerIamProgramInvalid
  | AwsAdminWorkerIamSessionUnavailable
  | AwsAdminWorkerExecutionFailed !AwsAdminWorkerExecutionCause
  | AwsAdminWorkerSessionRevocationFailed !AwsAdminWorkerSessionClosureCause
  | AwsAdminWorkerCompletionUnavailable
  | AwsAdminWorkerUnhandledException
  deriving stock (Eq, Show)

runAwsAdminWorker :: AwsAdminWorkerOptions -> IO ExitCode
runAwsAdminWorker options = emitWorkerResult =<< runWorker productionDeliveryResolver options

runAwsAdminWorkerWith
  :: AwsAdminDeliveryBoundary IO
  -> AwsAdminWorkerOptions
  -> IO ExitCode
runAwsAdminWorkerWith delivery options = do
  result <-
    runWorker
      (\_ _ _ _ -> pure (Right (ResolvedAwsAdminDelivery delivery (\_ _ -> pure (Right ())))))
      options
  emitWorkerResult result

data ResolvedAwsAdminDelivery = ResolvedAwsAdminDelivery
  { resolvedAwsAdminDirectDelivery :: !(AwsAdminDeliveryBoundary IO)
  , resolvedAwsAdminRetainedDelivery
      :: !( RetainedMaterialSource 'RetainedSesSmtpMaterial
            -> SignedAwsAdminPermit
            -> IO (Either Text ())
          )
  }

emitWorkerResult :: Either AwsAdminWorkerError AwsAdminWorkerReceipt -> IO ExitCode
emitWorkerResult result =
  case result of
    Left err -> do
      writeDiagnosticLine
        ( "AWS-admin credential worker refused: "
            <> Text.unpack (renderAwsAdminWorkerTerminalCause (workerTerminalCause err))
        )
      pure (ExitFailure 1)
    Right receipt -> do
      ByteString.hPut stdout ("\n" <> encodeAwsAdminWorkerReceiptTextEnvelope receipt)
      pure ExitSuccess

workerTerminalCause :: AwsAdminWorkerError -> AwsAdminWorkerTerminalCause
workerTerminalCause err = case err of
  AwsAdminWorkerDeliveryCompositionUnavailable -> AwsAdminWorkerTerminalDeliveryCompositionUnavailable
  AwsAdminWorkerStdinReadFailed -> AwsAdminWorkerTerminalStdinReadFailed
  AwsAdminWorkerStdinTooLarge _ _ -> AwsAdminWorkerTerminalStdinTooLarge
  AwsAdminWorkerFrameRejected _ -> AwsAdminWorkerTerminalFrameRejected
  AwsAdminWorkerPodIdentityReadFailed -> AwsAdminWorkerTerminalPodIdentityReadFailed
  AwsAdminWorkerPodIdentityInvalid -> AwsAdminWorkerTerminalPodIdentityInvalid
  AwsAdminWorkerPodIdentityMismatch -> AwsAdminWorkerTerminalPodIdentityMismatch
  AwsAdminWorkerPermitMetadataMismatch -> AwsAdminWorkerTerminalPermitMetadataMismatch
  AwsAdminWorkerModeMismatch -> AwsAdminWorkerTerminalModeMismatch
  AwsAdminWorkerProjectedIdentityMismatch -> AwsAdminWorkerTerminalProjectedIdentityMismatch
  AwsAdminWorkerClockUnavailable -> AwsAdminWorkerTerminalClockUnavailable
  AwsAdminWorkerVaultLoginUnavailable -> AwsAdminWorkerTerminalVaultLoginUnavailable
  AwsAdminWorkerAuthorityKeyUnavailable -> AwsAdminWorkerTerminalAuthorityKeyUnavailable
  AwsAdminWorkerPermitRejected -> AwsAdminWorkerTerminalPermitRejected
  AwsAdminWorkerIamProgramInvalid -> AwsAdminWorkerTerminalIamProgramInvalid
  AwsAdminWorkerIamSessionUnavailable -> AwsAdminWorkerTerminalIamSessionUnavailable
  AwsAdminWorkerExecutionFailed cause -> AwsAdminWorkerTerminalExecutionFailed cause
  AwsAdminWorkerSessionRevocationFailed cause ->
    AwsAdminWorkerTerminalSessionRevocationFailed cause
  AwsAdminWorkerCompletionUnavailable -> AwsAdminWorkerTerminalCompletionUnavailable
  AwsAdminWorkerUnhandledException -> AwsAdminWorkerTerminalUnhandledException

runWorker
  :: ( VaultSession
       -> AuthorityTime
       -> SignedAwsAdminPermit
       -> AwsAdminWorkerOptions
       -> IO (Either AwsAdminWorkerError ResolvedAwsAdminDelivery)
     )
  -> AwsAdminWorkerOptions
  -> IO (Either AwsAdminWorkerError AwsAdminWorkerReceipt)
runWorker resolveDelivery options = do
  stdinResult <- readHandleBounded awsAdminWorkerIngressMaximumBytes stdin
  podNameResult <- readPodIdentity (awsAdminWorkerPodNameFile options)
  podUidResult <- readPodIdentity (awsAdminWorkerPodUidFile options)
  case (stdinResult, podNameResult, podUidResult) of
    (Left err, _, _) -> pure (Left err)
    (_, Left err, _) -> pure (Left err)
    (_, _, Left err) -> pure (Left err)
    (Right input, Right podName, Right podUid) ->
      case withAwsAdminWorkerIngress input (execute podName podUid) of
        Left err -> pure (Left (AwsAdminWorkerFrameRejected err))
        Right effect -> effect
 where
  execute podName podUid permit credentials
    | not (permitMatchesOptions options permit) =
        pure (Left AwsAdminWorkerPermitMetadataMismatch)
    | not (permitModeMatches (awsAdminWorkerExpectedMode options) permit) =
        pure (Left AwsAdminWorkerModeMismatch)
    | awsAdminJobPodName binding /= podName
        || awsAdminJobPodUid binding /= podUid =
        pure (Left AwsAdminWorkerPodIdentityMismatch)
    | otherwise = do
        nowResult <- currentTime
        case nowResult of
          Left err -> pure (Left err)
          Right now ->
            withWorkerVaultSession options permit podName podUid $ \session ->
              executeAuthenticated resolveDelivery options session now permit credentials
   where
    binding = signedAwsAdminPermitBinding permit

permitMatchesOptions :: AwsAdminWorkerOptions -> SignedAwsAdminPermit -> Bool
permitMatchesOptions options permit =
  operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
    == awsAdminWorkerExpectedOperationId options
    && operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
      == awsAdminWorkerExpectedPermitId options
    && targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
      == awsAdminWorkerExpectedRequestDigest options
    && authorityTimeMicros (awsAdminPermitIntentDeadline intent)
      == awsAdminWorkerExpectedDeadlineMicros options
    && awsAdminPermitIntentImageDigest intent
      == awsAdminWorkerExpectedImageDigest options
    && awsAdminPermitIntentAuthorityScope intent
      == awsAdminWorkerExpectedAuthorityScope options
    && awsAdminPermitIntentAuthorityEndpoint intent
      == awsAdminWorkerExpectedAuthorityEndpoint options
 where
  intent = signedAwsAdminPermitIntent permit

permitModeMatches :: AwsAdminWorkerMode -> SignedAwsAdminPermit -> Bool
permitModeMatches mode permit = case (mode, awsAdminPermitIntentKind intent) of
  (AwsAdminNormalMode, NormalOperatorMaterialKind) -> True
  (AwsAdminNormalMode, CleanupRecoveryKind NormalOperatorMaterialCleanupProgram _) -> True
  (AwsAdminGenesisBackupMode, GenesisBackupKind _) -> True
  (AwsAdminGenesisBackupMode, CleanupRecoveryKind (GenesisBackupCleanupProgram _) _) -> True
  (AwsAdminBackupRepairMode, BackupRepairFrozenKind _) -> True
  _ -> False
 where
  intent = signedAwsAdminPermitIntent permit

executeAuthenticated
  :: ( VaultSession
       -> AuthorityTime
       -> SignedAwsAdminPermit
       -> AwsAdminWorkerOptions
       -> IO (Either AwsAdminWorkerError ResolvedAwsAdminDelivery)
     )
  -> AwsAdminWorkerOptions
  -> VaultSession
  -> AuthorityTime
  -> SignedAwsAdminPermit
  -> Credentials
  -> IO (Either AwsAdminWorkerError AwsAdminWorkerReceipt)
executeAuthenticated resolveDelivery options session now permit credentials = do
  publicResult <-
    readAuthorityManifestPublicKey (vaultAuthorityManifestSigner session)
  case publicResult of
    Left _ -> pure (Left AwsAdminWorkerAuthorityKeyUnavailable)
    Right (generation, publicKey)
      | generation /= signedAwsAdminPermitSignerGeneration permit ->
          pure (Left AwsAdminWorkerPermitRejected)
      | otherwise -> case verifySignedAwsAdminPermit
          (manifestPublicKeyBytes publicKey)
          generation
          now
          permit of
          Left _ -> pure (Left AwsAdminWorkerPermitRejected)
          Right () -> case credentialIamParametersProgram
            (awsAdminPermitIntentIamParameters (signedAwsAdminPermitIntent permit)) of
            Left _ -> pure (Left AwsAdminWorkerIamProgramInvalid)
            Right program -> case openProductionIamSession program credentials of
              Left _ -> pure (Left AwsAdminWorkerIamSessionUnavailable)
              Right iamSession -> do
                tokenResult <- sessionToken session
                deliveryResult <- resolveDelivery session now permit options
                case (tokenResult, deliveryResult) of
                  (Left _, _) -> pure (Left AwsAdminWorkerVaultLoginUnavailable)
                  (_, Left err) -> pure (Left err)
                  (Right token, Right delivery) -> do
                    executed <-
                      executeAwsAdminPermit
                        ( vaultAwsAdminExecutionJournalBoundary
                            (sessionAddress session)
                            token
                            permit
                        )
                        (productionAwsAdminIamBoundary iamSession)
                        ( productionRetainedCustodyAwsAdminDelivery
                            session
                            now
                            (resolvedAwsAdminRetainedDelivery delivery)
                            (resolvedAwsAdminDirectDelivery delivery)
                        )
                        permit
                    pure
                      ( first
                          (AwsAdminWorkerExecutionFailed . classifyAwsAdminExecutionError)
                          executed
                      )

-- | Revoke response is provisional; the exact accessor and correlated role
-- inventory must both reach stable absence before a receipt can escape.
finishAwsAdminWorkerSession
  :: IO (Either AwsAdminWorkerError value)
  -> IO (Either AwsAdminWorkerError ())
  -> IO (Either AwsAdminWorkerError Bool)
  -> IO (Either AwsAdminWorkerError value)
finishAwsAdminWorkerSession =
  finishClosedSession
    AwsAdminWorkerUnhandledException
    (AwsAdminWorkerSessionRevocationFailed AwsAdminWorkerSessionClosureAbsenceUnproven)

data WorkerVaultLogin = WorkerVaultLogin
  { workerLoginSession :: !VaultSession
  , workerLoginAccessor :: !Text
  }

withWorkerVaultSession
  :: AwsAdminWorkerOptions
  -> SignedAwsAdminPermit
  -> Text
  -> Text
  -> (VaultSession -> IO (Either AwsAdminWorkerError AwsAdminWorkerReceipt))
  -> IO (Either AwsAdminWorkerError AwsAdminWorkerReceipt)
withWorkerVaultSession options permit podName podUid action = do
  jwtResult <- readProjectedToken (awsAdminWorkerServiceAccountTokenFile options)
  case jwtResult of
    Left _ -> pure (Left AwsAdminWorkerVaultLoginUnavailable)
    Right jwt -> case decodeProjectedServiceAccountIdentity jwt of
      Left _ -> pure (Left AwsAdminWorkerProjectedIdentityMismatch)
      Right identity
        | not
            ( projectedServiceAccountIdentityMatches
                awsAdminWorkerNamespace
                podName
                podUid
                (awsAdminJobServiceAccount binding)
                (awsAdminJobServiceAccountUid binding)
                identity
            ) ->
            pure (Left AwsAdminWorkerProjectedIdentityMismatch)
        | otherwise -> do
            auditorResult <- newWorkerAuditor jwt
            case auditorResult of
              Left err -> pure (Left err)
              Right auditor -> do
                let repository =
                      vaultServiceSessionJournalRepository
                        workerVaultAddress
                        (vaultLoginToken auditor)
                        credentialProvisionerVaultRole
                allocated <-
                  allocateNextServiceSessionBinding
                    repository
                    credentialProvisionerVaultRole
                    (operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent))
                    (workerAttemptId permit)
                case allocated of
                  Left _ ->
                    pure
                      ( Left
                          ( AwsAdminWorkerSessionRevocationFailed
                              AwsAdminWorkerSessionClosureBindingAllocationFailed
                          )
                      )
                  Right sessionBinding -> do
                    actionError <- newIORef Nothing
                    actionProgress <- newIORef AwsAdminWorkerActionNotStarted
                    result <-
                      withFencedServiceSession
                        repository
                        (workerAccessorAuditOps auditor)
                        (workerSessionSubjects (awsAdminJobServiceAccountUid binding))
                        sessionBinding
                        (workerLoginBoundary jwt)
                        (runAction actionError actionProgress)
                    case result of
                      Left lifecycleError -> do
                        original <- readIORef actionError
                        progress <- readIORef actionProgress
                        pure (Left (mapLifecycleError original progress lifecycleError))
                      Right receipt -> commitWorkerCompletion jwt permit receipt
 where
  intent = signedAwsAdminPermitIntent permit
  binding = signedAwsAdminPermitBinding permit
  runAction actionError actionProgress login = do
    writeIORef actionProgress AwsAdminWorkerActionAttempted
    result <- action (workerLoginSession login)
    case result of
      Left err -> do
        writeIORef actionError (Just err)
        pure (Left "AWS-admin execution refused")
      Right value -> pure (Right value)

newWorkerVaultSession
  :: Text -> IO (Either AwsAdminWorkerError WorkerVaultLogin)
newWorkerVaultSession jwt = do
  result <-
    vaultKubernetesLoginWithLease
      workerVaultAddress
      workerVaultAuthPath
      credentialProvisionerVaultRole
      jwt
  case result of
    Left _ -> pure (Left AwsAdminWorkerVaultLoginUnavailable)
    Right login
      | not (validWorkerLogin login) -> do
          _ <- vaultRevokeSelf workerVaultAddress (vaultLoginToken login)
          pure (Left AwsAdminWorkerVaultLoginUnavailable)
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
  :: Text -> IO (Either AwsAdminWorkerError VaultKubernetesLoginResult)
newWorkerAuditor jwt = seek workerAuditorRecoveryAttempts []
 where
  seek remaining leakedAccessors
    | remaining <= 0 =
        pure
          ( Left
              ( AwsAdminWorkerSessionRevocationFailed
                  AwsAdminWorkerSessionClosureAuditorLoginFailed
              )
          )
    | otherwise = do
        loggedIn <-
          vaultKubernetesLoginWithLease
            workerVaultAddress
            workerVaultAuthPath
            credentialProvisionerAuditorVaultRole
            jwt
        case loggedIn of
          Left _ -> seek (remaining - 1) leakedAccessors
          Right auditor
            | isExactBoundedBatchAuditorLogin
                credentialProvisionerAuditorMaximumLeaseSeconds
                auditor -> do
                closed <-
                  closeWorkerRoleAccessors
                    auditor
                    credentialProvisionerAuditorVaultRole
                    (reverse leakedAccessors)
                pure $ case closed of
                  Left _ ->
                    Left
                      ( AwsAdminWorkerSessionRevocationFailed
                          AwsAdminWorkerSessionClosureAuditorRoleCleanupFailed
                      )
                  Right () -> Right auditor
            | isBoundedBatchAuditorLogin
                credentialProvisionerAuditorMaximumLeaseSeconds
                auditor -> do
                -- A shorter issued lease cannot contain the compiled child
                -- runtime even when its type/accessor/renewability shape is
                -- otherwise valid. Refuse before entering the fenced action.
                _ <- vaultRevokeSelf workerVaultAddress (vaultLoginToken auditor)
                pure
                  ( Left
                      ( AwsAdminWorkerSessionRevocationFailed
                          AwsAdminWorkerSessionClosureAuditorLeaseInsufficient
                      )
                  )
            | otherwise -> do
                -- A drifted role may return an accessor-bearing service
                -- token. Revoke its bearer now, retain any canonical
                -- accessor, then require a later valid batch auditor to prove
                -- the entire role inventory stably empty.
                _ <- vaultRevokeSelf workerVaultAddress (vaultLoginToken auditor)
                let nextAccessors = case canonicalWorkerAccessor (vaultLoginAccessor auditor) of
                      Nothing -> leakedAccessors
                      Just accessor -> accessor : leakedAccessors
                seek (remaining - 1) nextAccessors

workerLoginBoundary :: Text -> ServiceSessionLoginBoundary WorkerVaultLogin
workerLoginBoundary jwt =
  ServiceSessionLoginBoundary
    { attemptServiceSessionLogin =
        first (Text.pack . show) <$> newWorkerVaultSession jwt
    , serviceSessionLoginAccessor = workerLoginAccessor
    , revokeServiceSessionLogin = \login ->
        first (Text.pack . show) <$> revokeWorkerSession (workerLoginSession login)
    }

revokeWorkerSession :: VaultSession -> IO (Either AwsAdminWorkerError ())
revokeWorkerSession session = do
  tokenResult <- sessionToken session
  case tokenResult of
    Left _ ->
      pure
        ( Left
            ( AwsAdminWorkerSessionRevocationFailed
                AwsAdminWorkerSessionClosureAbsenceUnproven
            )
        )
    Right token -> do
      revoked <- vaultRevokeSelf (sessionAddress session) token
      pure
        ( either
            ( const
                ( Left
                    ( AwsAdminWorkerSessionRevocationFailed
                        AwsAdminWorkerSessionClosureAbsenceUnproven
                    )
                )
            )
            Right
            revoked
        )

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
      { vaultAccessorSubjectPolicies = ["default", credentialProvisionerVaultRole]
      , vaultAccessorSubjectMetadata =
          Map.fromList
            ( [ ("role", credentialProvisionerVaultRole)
              , ("service_account_name", credentialProvisionerVaultRole)
              , ("service_account_namespace", awsAdminWorkerNamespace)
              ]
                <> maybe [] (\uid -> [("service_account_uid", uid)]) maybeUid
            )
      , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
      }

mapLifecycleError
  :: Maybe AwsAdminWorkerError
  -> AwsAdminWorkerActionProgress
  -> ServiceSessionLifecycleError
  -> AwsAdminWorkerError
mapLifecycleError original actionProgress lifecycleError = case lifecycleError of
  ServiceSessionLifecycleActionFailed _ ->
    maybe
      (AwsAdminWorkerExecutionFailed AwsAdminWorkerExecutionUnclassified)
      id
      original
  ServiceSessionLifecycleLoginFailedCleaned _ -> AwsAdminWorkerVaultLoginUnavailable
  ServiceSessionLifecycleAccessorInvalid -> AwsAdminWorkerVaultLoginUnavailable
  ServiceSessionLifecycleAccessorIdentityMismatch -> AwsAdminWorkerVaultLoginUnavailable
  ServiceSessionLifecycleUnhandledException ->
    maybe AwsAdminWorkerUnhandledException id original
  _ ->
    AwsAdminWorkerSessionRevocationFailed
      (classifySessionClosureError actionProgress lifecycleError)

classifySessionClosureError
  :: AwsAdminWorkerActionProgress
  -> ServiceSessionLifecycleError
  -> AwsAdminWorkerSessionClosureCause
classifySessionClosureError actionProgress lifecycleError = case lifecycleError of
  ServiceSessionLifecycleJournalFailed _ ->
    AwsAdminWorkerSessionClosureJournalCommitFailed
  ServiceSessionLifecycleJournalUnavailable detail ->
    classifyAwsAdminWorkerJournalUnavailable actionProgress detail
  ServiceSessionLifecycleBindingRoleMismatch ->
    AwsAdminWorkerSessionClosureBindingRoleMismatch
  ServiceSessionLifecycleRoleOccupied ->
    AwsAdminWorkerSessionClosureRoleOccupied
  ServiceSessionLifecycleBindingInvalid _ ->
    AwsAdminWorkerSessionClosureBindingInvalid
  ServiceSessionLifecyclePrecleanFailed auditError ->
    classifyPrecleanAuditError auditError
  ServiceSessionLifecycleLoginFailedCleaned _ ->
    AwsAdminWorkerSessionClosureAbsenceUnproven
  ServiceSessionLifecycleLoginAmbiguityCleaned ->
    AwsAdminWorkerSessionClosureLoginAmbiguityCleaned
  ServiceSessionLifecycleAccessorInvalid ->
    AwsAdminWorkerSessionClosureAbsenceUnproven
  ServiceSessionLifecycleAccessorIdentityMismatch ->
    AwsAdminWorkerSessionClosureAbsenceUnproven
  ServiceSessionLifecycleCleanupFailed auditError ->
    classifyCleanupAuditError auditError
  ServiceSessionLifecycleCleanupThrew ->
    AwsAdminWorkerSessionClosureCleanupThrew
  ServiceSessionLifecycleCleanupJournalFailed _ ->
    AwsAdminWorkerSessionClosureCleanupJournalCommitFailed
  ServiceSessionLifecycleActionFailed _ ->
    AwsAdminWorkerSessionClosureAbsenceUnproven
  ServiceSessionLifecycleUnhandledException ->
    AwsAdminWorkerSessionClosureAbsenceUnproven

classifyPrecleanAuditError
  :: VaultAccessorAuditError
  -> AwsAdminWorkerSessionClosureCause
classifyPrecleanAuditError auditError = case auditError of
  VaultAccessorAuditIdentityInvalid ->
    AwsAdminWorkerSessionClosurePrecleanIdentityInvalid
  VaultAccessorAuditorLoginFailed ->
    AwsAdminWorkerSessionClosurePrecleanObservationFailed
  VaultAccessorAuditorEvidenceInvalid ->
    AwsAdminWorkerSessionClosurePrecleanObservationFailed
  VaultAccessorObservationFailed ->
    AwsAdminWorkerSessionClosurePrecleanObservationFailed
  VaultAccessorClassificationFailed ->
    AwsAdminWorkerSessionClosurePrecleanClassificationFailed
  VaultAccessorKnownIdentityMismatch ->
    AwsAdminWorkerSessionClosurePrecleanIdentityInvalid
  VaultAccessorRevocationFailed ->
    AwsAdminWorkerSessionClosurePrecleanStableAbsenceFailed
  VaultAccessorVisibilityWaitFailed ->
    AwsAdminWorkerSessionClosurePrecleanVisibilityWaitFailed
  VaultAccessorStableAbsenceFailed ->
    AwsAdminWorkerSessionClosurePrecleanStableAbsenceFailed

classifyCleanupAuditError
  :: VaultAccessorAuditError
  -> AwsAdminWorkerSessionClosureCause
classifyCleanupAuditError auditError = case auditError of
  VaultAccessorAuditIdentityInvalid ->
    AwsAdminWorkerSessionClosureCleanupIdentityInvalid
  VaultAccessorAuditorLoginFailed ->
    AwsAdminWorkerSessionClosureCleanupObservationFailed
  VaultAccessorAuditorEvidenceInvalid ->
    AwsAdminWorkerSessionClosureCleanupObservationFailed
  VaultAccessorObservationFailed ->
    AwsAdminWorkerSessionClosureCleanupObservationFailed
  VaultAccessorClassificationFailed ->
    AwsAdminWorkerSessionClosureCleanupClassificationFailed
  VaultAccessorKnownIdentityMismatch ->
    AwsAdminWorkerSessionClosureCleanupIdentityInvalid
  VaultAccessorRevocationFailed ->
    AwsAdminWorkerSessionClosureCleanupStableAbsenceFailed
  VaultAccessorVisibilityWaitFailed ->
    AwsAdminWorkerSessionClosureCleanupVisibilityWaitFailed
  VaultAccessorStableAbsenceFailed ->
    AwsAdminWorkerSessionClosureCleanupStableAbsenceFailed

commitWorkerCompletion
  :: Text
  -> SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> IO (Either AwsAdminWorkerError AwsAdminWorkerReceipt)
commitWorkerCompletion jwt permit receipt = do
  loggedIn <-
    vaultKubernetesLoginWithLease
      workerVaultAddress
      workerVaultAuthPath
      credentialProvisionerCompletionVaultRole
      jwt
  case loggedIn of
    Left _ -> pure (Left AwsAdminWorkerCompletionUnavailable)
    Right completionLogin
      | not
          ( isBoundedBatchAuditorLogin
              workerCompletionMaximumLeaseSeconds
              completionLogin
          ) -> do
          _ <-
            cleanupInvalidWorkerRoleLogin
              jwt
              credentialProvisionerCompletionVaultRole
              completionLogin
          pure (Left AwsAdminWorkerCompletionUnavailable)
      | otherwise -> do
          completionSession <-
            newVaultSession
              workerVaultAddress
              realSessionClock
              ( pure
                  ( Right
                      LoginLease
                        { loginLeaseToken = vaultLoginToken completionLogin
                        , loginLeaseSeconds = vaultLoginLeaseSeconds completionLogin
                        , loginLeaseRenewable = False
                        }
                  )
              )
          configured <- completionTransport completionSession permit
          case configured of
            Left err -> pure (Left err)
            Right transport -> do
              completed <-
                completeAwsAdminProvisioning
                  (awsAdminProvisionerClient transport)
                  (operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent))
                  permit
                  receipt
              pure $ case completed of
                Right confirmed | confirmed == receipt -> Right confirmed
                _ -> Left AwsAdminWorkerCompletionUnavailable
 where
  intent = signedAwsAdminPermitIntent permit

cleanupInvalidWorkerRoleLogin
  :: Text
  -> Text
  -> VaultKubernetesLoginResult
  -> IO (Either Text ())
cleanupInvalidWorkerRoleLogin jwt role login = do
  _ <- vaultRevokeSelf workerVaultAddress (vaultLoginToken login)
  auditorResult <- newWorkerAuditor jwt
  case auditorResult of
    Left err -> pure (Left (Text.pack (show err)))
    Right auditor ->
      closeWorkerRoleAccessors
        auditor
        role
        (maybe [] pure (canonicalWorkerAccessor (vaultLoginAccessor login)))

closeWorkerRoleAccessors
  :: VaultKubernetesLoginResult
  -> Text
  -> [Text]
  -> IO (Either Text ())
closeWorkerRoleAccessors auditor role knownAccessors = proveKnown knownAccessors
 where
  ops = workerAccessorAuditOps auditor
  subject = workerRoleAccessorSubject role

  proveKnown [] =
    first (Text.pack . show)
      <$> revokeAndProveVaultAccessorSubjectAbsent ops subject Nothing
  proveKnown (accessor : remaining) = do
    _ <- auditRevokeAccessor ops accessor
    proved <-
      first (Text.pack . show)
        <$> revokeAndProveVaultAccessorSubjectAbsent ops subject (Just accessor)
    case proved of
      Left detail -> pure (Left detail)
      Right () -> proveKnown remaining

workerRoleAccessorSubject :: Text -> VaultAccessorSubject
workerRoleAccessorSubject role =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["default", role]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", role)
          , ("service_account_name", credentialProvisionerVaultRole)
          , ("service_account_namespace", awsAdminWorkerNamespace)
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

canonicalWorkerAccessor :: Text -> Maybe Text
canonicalWorkerAccessor raw
  | Text.null raw = Nothing
  | Text.length raw > 512 = Nothing
  | Text.strip raw /= raw = Nothing
  | Text.any (\character -> isControl character || isSpace character) raw = Nothing
  | otherwise = Just raw

completionTransport
  :: VaultSession
  -> SignedAwsAdminPermit
  -> IO
       ( Either
           AwsAdminWorkerError
           (AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
       )
completionTransport session permit = do
  signerResult <-
    resolveTransitRequestSigningCapability
      session
      CallerCredentialProvisionerCompletion
      (controlPlaneSigningKeyRefFor CallerCredentialProvisionerCompletion)
  pure $ do
    signer <- first (const AwsAdminWorkerCompletionUnavailable) signerResult
    bounds <-
      first
        (const AwsAdminWorkerCompletionUnavailable)
        ( mkAuthenticatedTransportBounds
            workerCompletionFrameMaximum
            workerCompletionMetadataMaximum
            workerCompletionEnvelopeMaximum
        )
    scope <-
      first
        (const AwsAdminWorkerCompletionUnavailable)
        (mkAuthorityScope (awsAdminPermitIntentAuthorityScope intent))
    lifetime <-
      first
        (const AwsAdminWorkerCompletionUnavailable)
        (authorityDurationFromMicros workerCompletionAuthenticationLifetimeMicros)
    endpoint <-
      first
        (const AwsAdminWorkerCompletionUnavailable)
        (mkLifecycleAuthorityEndpoint (awsAdminPermitIntentAuthorityEndpoint intent))
    client <-
      first
        (const AwsAdminWorkerCompletionUnavailable)
        ( newControlPlaneClient
            awsAdminAuthorityHttpConfig
            awsAdminProvisionerResponseMaximumBytes
            endpoint
        )
    let providers =
          transitAuthenticatedClientProviders
            signer
            (pure (Right scope))
            (readRetainedAuthorityEpoch session)
            lifetime
    Right (mkAuthenticatedClientTransport bounds providers client)
 where
  intent = signedAwsAdminPermitIntent permit

productionDeliveryResolver
  :: VaultSession
  -> AuthorityTime
  -> SignedAwsAdminPermit
  -> AwsAdminWorkerOptions
  -> IO (Either AwsAdminWorkerError ResolvedAwsAdminDelivery)
productionDeliveryResolver session _ permit options = do
  authorityResult <- deliveryAuthorityTransports session permit
  targetResult <- targetAgentTransport session permit
  pure $ do
    (authorityTransport, retainedAuthorityTransport) <- authorityResult
    targetTransport <- targetResult
    let boundary =
          productionTargetMaterializationBoundary
            workerVaultAddress
            workerVaultAuthPath
            credentialProvisionerAuditorVaultRole
            (first Text.pack <$> readProjectedToken (awsAdminWorkerServiceAccountTokenFile options))
            TargetWorkerJobConnection
              { targetWorkerJobEnvironment = Nothing
              , targetWorkerJobWorkingDirectory = "/run/prodbox"
              , targetWorkerJobImageRepository = awsAdminWorkerTargetImageRepository options
              , targetWorkerJobMaximumRuntimeSeconds = awsAdminTargetWorkerMaximumRuntimeSeconds
              }
            (targetIntentAuthorityClient authorityTransport)
            (first (Text.pack . show) <$> currentTime)
        directDelivery =
          productionAwsAdminDeliveryBoundary
            boundary
            (targetMaterialClient targetTransport)
            permit
        retainedDelivery source retainedPermit = do
          let retainedIntent = signedAwsAdminPermitIntent retainedPermit
              prepared = awsAdminPermitIntentPreparedTarget retainedIntent
              request =
                retainedMaterialDeliveryWireRequest
                  SRetainedSesSmtpMaterial
                  source
                  ( "delivery-"
                      <> operatorMaterialOperationIdText
                        (awsAdminPermitIntentOperationId retainedIntent)
                  )
                  ( targetAgentClusterIdentity
                      (preparedCredentialTargetSelectedAgent prepared)
                  )
                  ( credentialGenerationValue
                      (awsAdminPermitIntentGeneration retainedIntent)
                  )
                  ( targetValueDigestText
                      (preparedCredentialTargetReceiptDigest prepared)
                  )
                  (awsAdminPermitIntentDeadline retainedIntent)
          result <-
            requestRetainedMaterialDelivery
              (retainedMaterialDeliveryClient retainedAuthorityTransport)
              request
          pure (first (Text.take 256 . Text.pack . show) (void result))
    Right (ResolvedAwsAdminDelivery directDelivery retainedDelivery)

deliveryAuthorityTransports
  :: VaultSession
  -> SignedAwsAdminPermit
  -> IO
       ( Either
           AwsAdminWorkerError
           ( AuthenticatedClientTransport 'LifecycleAuthorityRuntime
           , AuthenticatedClientTransport 'LifecycleAuthorityRuntime
           )
       )
deliveryAuthorityTransports session permit = do
  signerResult <-
    resolveTransitRequestSigningCapability
      session
      CallerCredentialProvisioner
      (controlPlaneSigningKeyRefFor CallerCredentialProvisioner)
  pure $ do
    signer <- first (const AwsAdminWorkerDeliveryCompositionUnavailable) signerResult
    bounds <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        ( mkAuthenticatedTransportBounds
            workerCompletionFrameMaximum
            workerCompletionMetadataMaximum
            workerCompletionEnvelopeMaximum
        )
    scope <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        (mkAuthorityScope (awsAdminPermitIntentAuthorityScope intent))
    lifetime <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        (authorityDurationFromMicros workerCompletionAuthenticationLifetimeMicros)
    endpoint <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        (mkLifecycleAuthorityEndpoint (awsAdminPermitIntentAuthorityEndpoint intent))
    client <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        ( newControlPlaneClient
            defaultHttpConfig
            awsAdminProvisionerResponseMaximumBytes
            endpoint
        )
    retainedClient <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        ( newControlPlaneClient
            awsAdminRetainedDeliveryHttpConfig
            awsAdminProvisionerResponseMaximumBytes
            endpoint
        )
    let providers =
          transitAuthenticatedClientProviders
            signer
            (pure (Right scope))
            (readRetainedAuthorityEpoch session)
            lifetime
    Right
      ( mkAuthenticatedClientTransport bounds providers client
      , mkAuthenticatedClientTransport bounds providers retainedClient
      )
 where
  intent = signedAwsAdminPermitIntent permit

awsAdminRetainedDeliveryHttpConfig :: HttpConfig
awsAdminRetainedDeliveryHttpConfig =
  defaultHttpConfig
    { httpRequestTimeoutMicros =
        RetainedMaterialDeliveryBudget.retainedMaterialDeliveryResponseTimeoutMicros
    }

awsAdminAuthorityHttpConfig :: HttpConfig
awsAdminAuthorityHttpConfig = defaultHttpConfig

targetAgentTransport
  :: VaultSession
  -> SignedAwsAdminPermit
  -> IO
       ( Either
           AwsAdminWorkerError
           (AuthenticatedClientTransport 'TargetSecretAgentRuntime)
       )
targetAgentTransport session permit = do
  signerResult <-
    resolveTransitRequestSigningCapability
      session
      CallerCredentialProvisioner
      (controlPlaneSigningKeyRefFor CallerCredentialProvisioner)
  pure $ do
    signer <- first (const AwsAdminWorkerDeliveryCompositionUnavailable) signerResult
    bounds <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        ( mkAuthenticatedTransportBounds
            workerCompletionFrameMaximum
            workerCompletionMetadataMaximum
            workerCompletionEnvelopeMaximum
        )
    scope <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        (mkAuthorityScope (awsAdminPermitIntentAuthorityScope intent))
    lifetime <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        (authorityDurationFromMicros workerCompletionAuthenticationLifetimeMicros)
    endpoint <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        (mkTargetSecretAgentEndpoint targetSecretAgentServiceEndpoint)
    client <-
      first
        (const AwsAdminWorkerDeliveryCompositionUnavailable)
        ( newControlPlaneClient
            defaultHttpConfig
            targetMaterialResponseMaximumBytes
            endpoint
        )
    let providers =
          transitAuthenticatedClientProviders
            signer
            (pure (Right scope))
            (readRetainedAuthorityEpoch session)
            lifetime
    Right (mkAuthenticatedClientTransport bounds providers client)
 where
  intent = signedAwsAdminPermitIntent permit

workerAttemptId :: SignedAwsAdminPermit -> Text
workerAttemptId permit =
  "permit-" <> sha256Text (encodeSignedAwsAdminPermit permit)

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

currentTime :: IO (Either AwsAdminWorkerError AuthorityTime)
currentTime = do
  attempted <- try getPOSIXTime :: IO (Either IOException POSIXTime)
  pure $ case attempted of
    Left _ -> Left AwsAdminWorkerClockUnavailable
    Right value
      | value < 0 -> Left AwsAdminWorkerClockUnavailable
      | otherwise ->
          Right (authorityTimeFromMicros (fromInteger (floor (value * 1000000))))

readPodIdentity :: FilePath -> IO (Either AwsAdminWorkerError Text)
readPodIdentity path = do
  attempted <- try (TextIO.readFile path) :: IO (Either IOException Text)
  pure $ case attempted of
    Left _ -> Left AwsAdminWorkerPodIdentityReadFailed
    Right raw
      | Text.null value -> Left AwsAdminWorkerPodIdentityInvalid
      | Text.length value > 256 -> Left AwsAdminWorkerPodIdentityInvalid
      | Text.any (<= '\x20') value -> Left AwsAdminWorkerPodIdentityInvalid
      | otherwise -> Right value
     where
      value = Text.strip raw

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
  :: Int -> Handle -> IO (Either AwsAdminWorkerError ByteString)
readHandleBounded maximumBytes handle = go ByteString.empty
 where
  go accumulated = do
    attempted <- try (ByteString.hGetSome handle 4096) :: IO (Either IOException ByteString)
    case attempted of
      Left _ -> pure (Left AwsAdminWorkerStdinReadFailed)
      Right chunk
        | ByteString.null chunk -> pure (Right accumulated)
        | ByteString.length accumulated + ByteString.length chunk > maximumBytes ->
            pure
              ( Left
                  ( AwsAdminWorkerStdinTooLarge
                      (ByteString.length accumulated + ByteString.length chunk)
                      maximumBytes
                  )
              )
        | otherwise -> go (accumulated <> chunk)

workerVaultAddress :: VaultAddress
workerVaultAddress = VaultAddress "http://vault.vault.svc.cluster.local:8200"

workerVaultAuthPath :: Text
workerVaultAuthPath = "kubernetes"

targetSecretAgentServiceEndpoint :: Text
targetSecretAgentServiceEndpoint =
  controlPlaneClusterServiceUrlText "target-secret-agent" "target-secret-agent"

awsAdminTargetWorkerMaximumRuntimeSeconds :: Natural
awsAdminTargetWorkerMaximumRuntimeSeconds = 180

awsAdminWorkerNamespace :: Text
awsAdminWorkerNamespace = "credential-provisioner"

workerMaximumLeaseSeconds :: Int
workerMaximumLeaseSeconds = 600

workerAuditorRecoveryAttempts :: Int
workerAuditorRecoveryAttempts = 4

workerCompletionMaximumLeaseSeconds :: Int
workerCompletionMaximumLeaseSeconds = 120

workerAccessorVisibilityGraceMicros :: Int
workerAccessorVisibilityGraceMicros = 1000000

workerCompletionFrameMaximum :: Int
workerCompletionFrameMaximum = 1024 * 1024

workerCompletionMetadataMaximum :: Int
workerCompletionMetadataMaximum = 64 * 1024

workerCompletionEnvelopeMaximum :: Int
workerCompletionEnvelopeMaximum = workerCompletionFrameMaximum - 4096

workerCompletionAuthenticationLifetimeMicros :: Natural
workerCompletionAuthenticationLifetimeMicros = 60 * 1000000
