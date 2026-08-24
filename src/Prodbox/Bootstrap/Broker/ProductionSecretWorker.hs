{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Executable interpreter for the Broker's sole attested one-shot worker.
-- The worker reconstructs its immutable request from the Kubernetes API,
-- consumes exactly one bounded stdin frame, performs one closed operation,
-- and publishes only ciphertext/non-secret evidence under a freshly
-- revalidated fence permit.
module Prodbox.Bootstrap.Broker.ProductionSecretWorker
  ( runProductionSecretWorker
  , classifyInitializationAmbiguity
  )
where

import Codec.Serialise (Serialise, serialise)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict'
  , withObject
  , (.:)
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Engine (RootInitCryptoParameters (..))
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceStoreObservation (..)
  , BootstrapSessionFence
  , BootstrapStoreMutation (..)
  , BootstrapStoreMutationPermit
  , BootstrapVaultEffect (..)
  , BootstrapVaultEffectPermit
  , authorizeBootstrapStoreMutation
  , authorizeBootstrapVaultEffect
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceOperationDeadline
  , bootstrapFenceOwnerNonce
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  )
import Prodbox.Bootstrap.Broker.KubernetesWorker
  ( KubernetesWorkerBoundary (..)
  , productionKubernetesWorkerBoundary
  , readProjectedServiceAccountToken
  )
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( GeneratedRootCiphertext
  , PreparedInitRecipients
  , decryptRecoveryShares
  , mkGeneratedRootCiphertext
  , prepareRecoveryRecipient
  , resumePreparedInitRecipients
  , sealFinalUnlockPayload
  , verifyCompiledBurnRecipient
  , withPgpSecretPayloadBytes
  )
import Prodbox.Bootstrap.Broker.PristineJournal
  ( classifyPristineJournal
  )
import Prodbox.Bootstrap.Broker.ProductionCryptoParameters
  ( productionRootInitCryptoParameters
  )
import Prodbox.Bootstrap.Broker.ProductionPgp
  ( openFinalUnlockPayload
  , productionPgpBoundary
  )
import Prodbox.Bootstrap.Broker.ProductionStore
  ( ProductionTransitRotationBoundary (..)
  , ProductionTransitRotationJournal (..)
  , observeProductionTransitRotationJournal
  , productionBootstrapStoreBoundary
  , productionSecretWorkerReceiptDigest
  , productionTransitRotationBoundary
  , publishProductionSecretWorkerResult
  )
import Prodbox.Bootstrap.Broker.Program
  ( BootstrapMutationReceipt (..)
  )
import Prodbox.Bootstrap.Broker.Request
  ( SecretPayload
  , mkSecretPayload
  )
import Prodbox.Bootstrap.Broker.SecretIngress
  ( readSecretIngressFrame
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( InitializationAmbiguityCause (..)
  , RawSecretWorkerReceipt (..)
  , SecretFreeWorkerRequest
  , SecretWorkerDurableResult
  , SecretWorkerOperation (..)
  , SecretWorkerOutcome (..)
  , classifiedAmbiguousInitializationWorkerResult
  , durableWorkerSessionAccessor
  , encryptedInitializationWorkerResult
  , finalizedInitializationWorkerResult
  , generatedRootCiphertextWorkerResult
  , preparedInitializationWorkerResult
  , resumedInitializationWorkerResult
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestOperation
  , secretWorkerRequestOperationDeadline
  , secretWorkerRequestOwnerNonce
  , secretWorkerRequestPodUid
  , secretWorkerRequestSessionId
  , secretWorkerRequestStorageGeneration
  , transitRotationWorkerResult
  , unlockRotationWorkerResult
  , unsealWorkerResult
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , brokerBurnRecipient
  , brokerVaultAddress
  , loadBootstrapBrokerConfig
  , renderBootstrapBrokerSettingsError
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  , StoreReadBack (..)
  , StoreVersion
  , StoreWriteResult (..)
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , EncryptedInitResponseReceipt
  , FinalUnlockBundle
  , PreparedInitEnvelope
  , RecoveredUnsealShare
  , RootInitBinding
  , finalPayloadShares
  , finalUnlockBundleBinding
  , mkArtifactDigest
  , mkEncryptedInitResponseReceipt
  , mkFinalUnlockBundle
  , mkFinalUnlockBundlePayload
  , renderArtifactDigest
  , rootInitStorageGeneration
  , withRecoveredUnsealShareBytes
  )
import Prodbox.Bootstrap.Broker.VaultWire
  ( EncryptedVaultInitResponse
  , encryptedVaultInitBurnToken
  , encryptedVaultInitShares
  )
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , RemainingDuration (..)
  , deadlineAtOffset
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.VaultAccessorAudit
  ( isBoundedBatchAuditorLogin
  )
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  )
import Prodbox.Vault.Client qualified as Vault
import Prodbox.Vault.Reconcile
  ( bootstrapBrokerRotatableTransitKeys
  )
import Prodbox.Vault.RoleId
  ( VaultRoleId (VaultRoleBootstrapBroker)
  , vaultRoleIdText
  )
import System.Exit (ExitCode (..))
import System.IO (stdin)

maximumIngressBytes :: Natural
maximumIngressBytes = 64 * 1024

runProductionSecretWorker
  :: FilePath
  -> SecretWorkerOperation
  -> IO ExitCode
runProductionSecretWorker configPath operation = do
  loaded <- loadBootstrapBrokerConfig configPath
  case loaded of
    Left failure -> failWorker (renderBootstrapBrokerSettingsError failure)
    Right settings -> do
      storeResult <- productionBootstrapStoreBoundary settings
      kubernetesResult <- productionKubernetesWorkerBoundary
      case (storeResult, kubernetesResult) of
        (Right store, Right kubernetes) ->
          runBoundWorker settings store kubernetes operation
        (Left _, _) -> failWorker "Bootstrap secret worker store is unavailable"
        (_, Left _) -> failWorker "Bootstrap secret worker Kubernetes boundary is unavailable"

runBoundWorker
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretWorkerOperation
  -> IO ExitCode
runBoundWorker settings store kubernetes operation = do
  requestResult <- observeSelfWorker kubernetes operation 120
  case requestResult of
    Left failure -> failWorker (Text.unpack failure)
    Right request -> do
      ingress <- readSecretIngressFrame maximumIngressBytes request stdin
      case ingress of
        Left _ -> failWorker "Bootstrap secret worker stdin frame was refused"
        Right payload -> do
          performed <- performOperation settings store kubernetes request payload
          case performed of
            Left failure -> failWorker failure
            Right result -> publishResult settings store kubernetes request result

observeSelfWorker
  :: KubernetesWorkerBoundary
  -> SecretWorkerOperation
  -> Int
  -> IO (Either Text SecretFreeWorkerRequest)
observeSelfWorker kubernetes operation attempts = do
  deadline <- shortDeadline
  observed <- kubernetesObserveSelfWorkerRequest kubernetes deadline operation
  case observed of
    Right request -> pure (Right request)
    Left failure
      | attempts <= 1 -> pure (Left failure)
      | otherwise -> do
          threadDelay 250000
          observeSelfWorker kubernetes operation (attempts - 1)

performOperation
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
performOperation settings store kubernetes request payload = do
  bindingResult <- exactRootBinding store request
  case bindingResult of
    Left failure -> pure (Left failure)
    Right binding -> case secretWorkerRequestOperation request of
      SecretWorkerPrepareInitialization ->
        prepareInitialization settings store kubernetes binding request payload
      SecretWorkerResumeInitialization ->
        resumeInitialization settings store binding payload
      SecretWorkerInitialize ->
        initializeVault settings store kubernetes binding request payload
      SecretWorkerFinalizeInitialization ->
        finalizeInitialization settings store binding payload
      SecretWorkerUnseal ->
        unsealVault settings store kubernetes binding request payload
      SecretWorkerRotateUnlockBundle ->
        rotateUnlockBundle store kubernetes binding request payload
      SecretWorkerRotateTransitKey ->
        rotateTransitKey settings store kubernetes request payload
      SecretWorkerCompleteGeneratedRoot ->
        completeGeneratedRoot settings store kubernetes binding request payload

prepareInitialization
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> RootInitBinding
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
prepareInitialization settings store kubernetes binding request payload = do
  journal <- readRootInitJournal store binding
  authorized <-
    authorizeWorkerVaultEffect
      store
      kubernetes
      request
      BootstrapVaultInitialize
  status <- case authorized of
    Left failure -> pure (Left failure)
    Right _ ->
      mapVaultFailure "Vault seal status is unavailable" <$> Vault.vaultSealStatus (vaultAddress settings)
  case status of
    Right observed
      | Vault.sealStatusInitialized observed ->
          pure (Left "Vault is already initialized")
      | otherwise ->
          case journal of
            Right observation ->
              case classifyPristineJournal binding observation of
                Right proof -> prepare proof
                Left _ -> pure (Left "Root initialization journal is not pristine")
            Left _ -> pure (Left "Pristine initialization evidence is unavailable")
    Left _ -> pure (Left "Pristine initialization evidence is unavailable")
 where
  prepare proof =
    case productionRootInitCryptoParameters settings proof of
      Left failure -> pure (Left failure)
      Right parameters -> do
        verified <-
          verifyCompiledBurnRecipient
            productionPgpBoundary
            (brokerBurnRecipient settings)
        case verified of
          Left _ -> pure (Left "Compiled burn recipient verification failed")
          Right burn -> do
            prepared <-
              prepareRecoveryRecipient
                productionPgpBoundary
                payload
                proof
                (rootInitCryptoSchemaVersion parameters)
                burn
                (rootInitCryptoShareCount parameters)
                (rootInitCryptoThreshold parameters)
                (rootInitCryptoEnvelopeDigest parameters)
            pure
              ( either
                  (const (Left "Recovery recipient preparation failed"))
                  (Right . preparedInitializationWorkerResult)
                  prepared
              )

resumeInitialization
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> RootInitBinding
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
resumeInitialization settings store binding payload = do
  prepared <- loadPreparedEnvelope store binding
  case prepared of
    Left failure -> pure (Left failure)
    Right envelope -> do
      recipients <- resumeRecipients settings payload envelope
      pure (resumedInitializationWorkerResult <$> recipients)

initializeVault
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> RootInitBinding
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
initializeVault settings store kubernetes binding request payload = do
  prepared <- loadPreparedEnvelope store binding
  case prepared of
    Left failure -> pure (Left failure)
    Right envelope -> do
      recipientsResult <- resumeRecipients settings payload envelope
      case recipientsResult of
        Left failure -> pure (Left failure)
        Right recipients -> do
          before <-
            authorizedVaultCall BootstrapVaultInitialize (Vault.vaultSealStatus (vaultAddress settings))
          case before of
            Right observed
              | Vault.sealStatusInitialized observed ->
                  pure
                    ( Right
                        ( classifiedAmbiguousInitializationWorkerResult
                            InitializationObservedBeforeCall
                        )
                    )
            Left _ -> pure (Left "Vault initialization status is unavailable")
            Right _ -> do
              authorized <-
                authorizeWorkerVaultEffect
                  store
                  kubernetes
                  request
                  BootstrapVaultInitialize
              case authorized of
                Left failure -> pure (Left failure)
                Right _ -> do
                  initialized <-
                    Vault.vaultInitEncrypted (vaultAddress settings) recipients
                  case initialized of
                    Right response ->
                      pure
                        ( encryptedInitializationWorkerResult
                            <$> encryptedReceipt envelope response
                        )
                    Left httpFailure -> do
                      after <-
                        authorizedVaultCall BootstrapVaultInitialize (Vault.vaultSealStatus (vaultAddress settings))
                      pure $ case after of
                        Right observed
                          | Vault.sealStatusInitialized observed ->
                              Right
                                ( classifiedAmbiguousInitializationWorkerResult
                                    (classifyInitializationAmbiguity httpFailure)
                                )
                        _ -> Left "Vault initialization failed before application was observed"
 where
  authorizedVaultCall effect action = do
    authorized <- authorizeWorkerVaultEffect store kubernetes request effect
    case authorized of
      Left failure -> pure (Left failure)
      Right _ -> mapVaultFailure "Vault initialization call failed" <$> action

classifyInitializationAmbiguity :: HttpError -> InitializationAmbiguityCause
classifyInitializationAmbiguity httpFailure = case httpFailure of
  HttpConnectionFailure _ -> InitializationCallConnectionFailure
  HttpTimeout _ -> InitializationCallTimeout
  HttpStatus code _ -> InitializationCallHttpStatus code
  HttpDecode _ -> InitializationCallResponseDecodeFailure

finalizeInitialization
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> RootInitBinding
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
finalizeInitialization settings store binding payload = do
  prepared <- loadPreparedEnvelope store binding
  encrypted <- loadEncryptedResponse store binding
  case (prepared, encrypted) of
    (Right envelope, Right response) -> do
      recipients <- resumeRecipients settings payload envelope
      case recipients of
        Left failure -> pure (Left failure)
        Right exactRecipients -> do
          shares <-
            decryptRecoveryShares
              productionPgpBoundary
              payload
              exactRecipients
              response
          case shares of
            Left _ -> pure (Left "Recovery-share decryption failed")
            Right recovered ->
              case mkFinalUnlockBundlePayload response recovered of
                Left _ -> pure (Left "Recovered-share custody evidence was invalid")
                Right finalPayload -> do
                  sealed <- sealFinalUnlockPayload productionPgpBoundary payload finalPayload
                  pure $ case sealed of
                    Left _ -> Left "Final unlock-bundle sealing failed"
                    Right (ciphertext, digest) ->
                      Right
                        ( finalizedInitializationWorkerResult
                            (mkFinalUnlockBundle finalPayload ciphertext digest)
                        )
    (Left failure, _) -> pure (Left failure)
    (_, Left failure) -> pure (Left failure)

unsealVault
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> RootInitBinding
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
unsealVault settings store kubernetes binding request payload = do
  bundle <- loadFinalBundle store binding
  case bundle of
    Left failure -> pure (Left failure)
    Right (_, finalBundle) ->
      withPgpSecretPayloadBytes
        payload
        (unsealWithPassword settings store kubernetes request finalBundle)

unsealWithPassword
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> FinalUnlockBundle
  -> ByteString
  -> IO (Either String SecretWorkerDurableResult)
unsealWithPassword settings store kubernetes request finalBundle passwordBytes =
  case openFinalUnlockPayload passwordBytes finalBundle of
    Left _ -> pure (Left "Unlock-bundle password was refused")
    Right finalPayload -> do
      unsealed <-
        submitUnsealShares
          store
          kubernetes
          request
          (vaultAddress settings)
          (finalPayloadShares finalPayload)
      pure $ do
        changed <- unsealed
        Right
          ( unsealWorkerResult
              BootstrapMutationReceipt
                { bootstrapMutationDigest = secretWorkerRequestActionDigest request
                , bootstrapMutationChanged = changed
                }
          )

rotateUnlockBundle
  :: BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> RootInitBinding
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
rotateUnlockBundle store kubernetes binding request payload = do
  parsed <-
    withPgpSecretPayloadBytes payload $ \bytes ->
      pure (eitherDecodeStrict' bytes)
  current <- loadFinalBundle store binding
  case (parsed, current) of
    (Left _, _) -> pure (Left "Unlock-rotation ingress was invalid")
    (_, Left failure) -> pure (Left failure)
    (Right rotation, Right (version, bundle)) ->
      rotateFrom version bundle rotation
 where
  rotateFrom version bundle rotation = do
    let currentPassword = TextEncoding.encodeUtf8 (unlockRotationCurrentPassword rotation)
        newPassword = TextEncoding.encodeUtf8 (unlockRotationNewPassword rotation)
    case openFinalUnlockPayload currentPassword bundle of
      Left _ ->
        case openFinalUnlockPayload newPassword bundle of
          Left _ -> pure (Left "Current and replacement unlock passwords were refused")
          Right _ -> pure (Right (rotationReceipt False))
      Right finalPayload ->
        case mkSecretPayload maximumIngressBytes newPassword of
          Left _ -> pure (Left "Replacement unlock password was invalid")
          Right replacement -> do
            sealed <- sealFinalUnlockPayload productionPgpBoundary replacement finalPayload
            case sealed of
              Left _ -> pure (Left "Replacement unlock bundle could not be sealed")
              Right (ciphertext, digest) -> do
                let replacementBundle = mkFinalUnlockBundle finalPayload ciphertext digest
                permit <-
                  authorizeWorkerStoreMutation
                    store
                    kubernetes
                    request
                    BootstrapStoreCasFinalUnlockBundle
                case permit of
                  Left failure -> pure (Left failure)
                  Right authorized -> do
                    written <- casFinalUnlockBundle store authorized version replacementBundle
                    pure $ case written of
                      Right (StoreWriteApplied _ _ observed)
                        | observed == replacementBundle ->
                            Right (rotationReceipt True)
                      Right (StoreWriteConflict (StoreObjectPresent _ _ observed))
                        | observed == replacementBundle -> Right (rotationReceipt False)
                      _ -> Left "Unlock-bundle rotation CAS was not read back exactly"

  rotationReceipt changed =
    unlockRotationWorkerResult
      BootstrapMutationReceipt
        { bootstrapMutationDigest = secretWorkerRequestActionDigest request
        , bootstrapMutationChanged = changed
        }

rotateTransitKey
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
rotateTransitKey settings store kubernetes request payload =
  withPgpSecretPayloadBytes payload rotateNamedKey
 where
  rotateNamedKey bytes =
    case TextEncoding.decodeUtf8' bytes of
      Left _ -> pure (Left "Transit-key name was not UTF-8")
      Right rawName -> do
        let keyName = Text.strip rawName
        if keyName `notElem` bootstrapBrokerRotatableTransitKeys
          then pure (Left "Transit-key name is not in the compiled rotation inventory")
          else do
            projected <- readProjectedServiceAccountToken
            case projected of
              Left _ -> pure (Left "Projected worker token is unavailable")
              Right jwt -> do
                loggedIn <-
                  authorizedTransitCall
                    ( Vault.vaultKubernetesLoginWithLease
                        (vaultAddress settings)
                        "kubernetes"
                        (vaultRoleIdText VaultRoleBootstrapBroker)
                        jwt
                    )
                case loggedIn of
                  Left _ -> pure (Left "Bootstrap worker Vault login failed")
                  Right login -> do
                    let token = Vault.vaultLoginToken login
                        evidenceValid = isBoundedBatchAuditorLogin 300 login
                    rotated <-
                      if evidenceValid
                        then rotateFromJournal token keyName
                        else
                          pure
                            ( Left
                                "Bootstrap worker Vault login did not return a bounded batch token"
                            )
                    revoked <-
                      authorizedTransitCall
                        (Vault.vaultRevokeSelf (vaultAddress settings) token)
                    pure $ case revoked of
                      Left _ ->
                        Left "Bootstrap worker Vault session revoke-self failed"
                      Right () -> case rotated of
                        Right () ->
                          Right
                            ( transitRotationWorkerResult
                                BootstrapMutationReceipt
                                  { bootstrapMutationDigest = secretWorkerRequestActionDigest request
                                  , bootstrapMutationChanged = True
                                  }
                            )
                        Left failure -> Left failure
  authorizedTransitCall action = do
    authorized <-
      authorizeWorkerVaultEffect
        store
        kubernetes
        request
        BootstrapVaultRotateTransitKey
    case authorized of
      Left failure -> pure (Left failure)
      Right _ -> mapVaultFailure "Bootstrap worker Vault call failed" <$> action

  rotateFromJournal token keyName = do
    currentResult <-
      authorizedTransitCall
        (Vault.vaultReadTransitKey (vaultAddress settings) token keyName)
    case currentResult of
      Left _ -> pure (Left "Transit-key pre-rotation read-back failed")
      Right current -> do
        observed <- observeProductionTransitRotationJournal settings
        case observed of
          Left _ -> pure (Left "Transit rotation journal is unavailable")
          Right StoreObjectAbsent -> planAndContinue token keyName current
          Right (StoreObjectPresent _ _ journal)
            | transitRotationRequestDigest journal == secretWorkerRequestDigest request
                && transitRotationStorageGeneration journal
                  == secretWorkerRequestStorageGeneration request
                && transitRotationKeyName journal == keyName ->
                continueRotation token current journal
            | otherwise -> case journal of
                ProductionTransitRotationApplied {} -> planAndContinue token keyName current
                ProductionTransitRotationPlanned {} ->
                  pure (Left "An unfinished predecessor Transit rotation remains journaled")

  planAndContinue token keyName current = do
    permit <-
      authorizeWorkerStoreMutation
        store
        kubernetes
        request
        BootstrapStorePlanTransitRotation
    case permit of
      Left failure -> pure (Left failure)
      Right authorized -> do
        planned <-
          planTransitRotation
            (productionTransitRotationBoundary settings)
            authorized
            request
            keyName
            (Vault.transitKeyLatestVersion current)
        case planned of
          Left _ -> pure (Left "Transit rotation plan was not durably read back")
          Right journal -> continueRotation token current journal

  continueRotation token current journal = case journal of
    ProductionTransitRotationApplied
      { transitRotationAfterVersion
      , transitRotationKeyName
      }
        | Vault.transitKeyName current == transitRotationKeyName
            && Vault.transitKeyLatestVersion current == transitRotationAfterVersion ->
            pure (Right ())
        | otherwise -> pure (Left "Applied Transit journal differs from Vault read-back")
    ProductionTransitRotationPlanned
      { transitRotationBeforeVersion
      , transitRotationKeyName
      }
        | Vault.transitKeyName current /= transitRotationKeyName ->
            pure (Left "Planned Transit journal key differs from Vault read-back")
        | Vault.transitKeyLatestVersion current == transitRotationBeforeVersion -> do
            applied <-
              authorizedTransitCall
                (Vault.vaultRotateTransitKey (vaultAddress settings) token transitRotationKeyName)
            case applied of
              Left _ -> pure (Left "Transit-key rotation response was unavailable")
              Right () -> observeAndComplete token journal
        | Vault.transitKeyLatestVersion current == transitRotationBeforeVersion + 1 ->
            completeJournal journal (Vault.transitKeyLatestVersion current)
        | otherwise ->
            pure (Left "Planned Transit journal cannot be reconciled with Vault version")

  observeAndComplete token journal = do
    after <-
      authorizedTransitCall
        ( Vault.vaultReadTransitKey
            (vaultAddress settings)
            token
            (transitRotationKeyName journal)
        )
    case after of
      Right current
        | Vault.transitKeyLatestVersion current
            == transitRotationBeforeVersion journal + 1 ->
            completeJournal journal (Vault.transitKeyLatestVersion current)
      _ -> pure (Left "Transit-key post-rotation read-back was not exact")

  completeJournal journal afterVersion = do
    permit <-
      authorizeWorkerStoreMutation
        store
        kubernetes
        request
        BootstrapStoreCompleteTransitRotation
    case permit of
      Left failure -> pure (Left failure)
      Right authorized -> do
        completed <-
          completeTransitRotation
            (productionTransitRotationBoundary settings)
            authorized
            request
            (transitRotationKeyName journal)
            (transitRotationBeforeVersion journal)
            afterVersion
        pure $ case completed of
          Right ProductionTransitRotationApplied {} -> Right ()
          _ -> Left "Transit rotation completion was not durably read back"

completeGeneratedRoot
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> RootInitBinding
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> IO (Either String SecretWorkerDurableResult)
completeGeneratedRoot settings store kubernetes binding request payload = do
  bundle <- loadFinalBundle store binding
  case bundle of
    Left failure -> pure (Left failure)
    Right (_, finalBundle) ->
      withPgpSecretPayloadBytes payload (completeWithPassword finalBundle)
 where
  completeWithPassword finalBundle passwordBytes =
    case openFinalUnlockPayload passwordBytes finalBundle of
      Left _ -> pure (Left "Unlock-bundle password was refused")
      Right finalPayload -> do
        observed <- authorizedGenerateRootCall (Vault.vaultObserveGenerateRoot address)
        completed <- case observed of
          Left failure -> pure (Left failure)
          Right response ->
            submitGenerateRootShares
              response
              (finalPayloadShares finalPayload)
        pure (generatedRootCiphertextWorkerResult <$> completed)

  address = vaultAddress settings

  authorizedGenerateRootCall action = do
    authorized <-
      authorizeWorkerVaultEffect
        store
        kubernetes
        request
        BootstrapVaultSubmitGenerateRootShare
    case authorized of
      Left failure -> pure (Left failure)
      Right _ -> mapVaultFailure "Vault generated-root call failed" <$> action

  submitGenerateRootShares
    :: Vault.GenerateRootResponse
    -> [RecoveredUnsealShare]
    -> IO (Either String GeneratedRootCiphertext)
  submitGenerateRootShares response shares
    | Vault.generateRootComplete response =
        pure (generatedCiphertextFromResponse response)
    | not (Vault.generateRootStarted response) =
        pure (Left "Vault generated-root attempt is not active")
    | Vault.generateRootRequired response == 0 =
        pure (Left "Vault generated-root threshold is invalid")
    | Vault.generateRootProgress response > Vault.generateRootRequired response =
        pure (Left "Vault generated-root progress exceeds its threshold")
    | Vault.generateRootRequired response > fromIntegral (length shares) =
        pure (Left "Unlock bundle does not contain enough generated-root shares")
    | otherwise = case Vault.generateRootNonce response of
        Nothing -> pure (Left "Vault generated-root nonce is absent")
        Just nonce ->
          go
            nonce
            (Vault.generateRootRequired response)
            (Vault.generateRootProgress response)
            (drop (fromIntegral (Vault.generateRootProgress response)) shares)

  go _ _ _ [] = pure (Left "Recovery shares were exhausted before generated-root completion")
  go nonce required priorProgress (share : rest) =
    withRecoveredUnsealShareBytes
      share
      (submitRecoveredShare nonce required priorProgress rest)
  submitRecoveredShare nonce required priorProgress rest bytes =
    case TextEncoding.decodeUtf8' bytes of
      Left _ -> pure (Left "A recovered Vault share was not UTF-8")
      Right key -> do
        submitted <-
          authorizedGenerateRootCall
            (Vault.vaultSubmitGenerateRootShare address nonce key)
        case submitted of
          Left failure -> pure (Left failure)
          Right response
            | Vault.generateRootComplete response ->
                pure (generatedCiphertextFromResponse response)
            | Vault.generateRootNonce response /= Just nonce ->
                pure (Left "Vault generated-root nonce changed during completion")
            | Vault.generateRootRequired response /= required ->
                pure (Left "Vault generated-root threshold changed during completion")
            | Vault.generateRootProgress response /= priorProgress + 1 ->
                pure (Left "Vault generated-root progress read-back was not exact")
            | otherwise ->
                go nonce required (Vault.generateRootProgress response) rest

  generatedCiphertextFromResponse response = do
    encoded <-
      maybe
        (Left "Vault completed generated-root without encrypted token ciphertext")
        Right
        (Vault.generateRootEncodedToken response)
    ciphertextBytes <-
      either
        (const (Left "Vault generated-root ciphertext was not canonical base64"))
        Right
        (Base64.decode (TextEncoding.encodeUtf8 encoded))
    either
      (const (Left "Vault generated-root ciphertext was invalid"))
      Right
      (mkGeneratedRootCiphertext ciphertextBytes)

publishResult
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> SecretWorkerDurableResult
  -> IO ExitCode
publishResult settings store kubernetes request result = do
  case rawReceipt request result of
    Left failure -> failWorker failure
    Right receipt -> do
      permit <-
        authorizeWorkerStoreMutation
          store
          kubernetes
          request
          BootstrapStorePublishSecretWorkerResult
      case permit of
        Left failure -> failWorker failure
        Right authorized -> do
          published <-
            publishProductionSecretWorkerResult
              settings
              authorized
              request
              receipt
              result
          case published of
            Left _ -> failWorker "Bootstrap secret-worker result publication failed"
            Right _ -> do
              written <-
                try
                  ( ByteString.writeFile
                      "/dev/termination-log"
                      (TextEncoding.encodeUtf8 (renderArtifactDigest (rawWorkerReceiptDigest receipt)))
                  )
                  :: IO (Either IOException ())
              case written of
                Left _ -> failWorker "Bootstrap secret-worker termination receipt could not be written"
                Right () -> pure ExitSuccess

rawReceipt
  :: SecretFreeWorkerRequest
  -> SecretWorkerDurableResult
  -> Either String RawSecretWorkerReceipt
rawReceipt request result = do
  digest <-
    either
      (const (Left "Bootstrap secret-worker receipt digest construction failed"))
      Right
      (productionSecretWorkerReceiptDigest request result)
  Right
    RawSecretWorkerReceipt
      { rawWorkerReceiptOperation = secretWorkerRequestOperation request
      , rawWorkerReceiptPodUid = secretWorkerRequestPodUid request
      , rawWorkerReceiptSessionId = secretWorkerRequestSessionId request
      , rawWorkerReceiptSessionAccessor = durableWorkerSessionAccessor result
      , rawWorkerReceiptRequestDigest = secretWorkerRequestDigest request
      , rawWorkerReceiptStorageGeneration = secretWorkerRequestStorageGeneration request
      , rawWorkerReceiptFenceGeneration = secretWorkerRequestFenceGeneration request
      , rawWorkerReceiptOutcome = outcomeFor (secretWorkerRequestOperation request)
      , rawWorkerReceiptDigest = digest
      }

outcomeFor :: SecretWorkerOperation -> SecretWorkerOutcome
outcomeFor operation = case operation of
  SecretWorkerPrepareInitialization -> SecretWorkerInitialized
  SecretWorkerResumeInitialization -> SecretWorkerInitialized
  SecretWorkerInitialize -> SecretWorkerInitialized
  SecretWorkerFinalizeInitialization -> SecretWorkerInitialized
  SecretWorkerUnseal -> SecretWorkerUnsealed
  SecretWorkerRotateUnlockBundle -> SecretWorkerUnlockBundleRotated
  SecretWorkerRotateTransitKey -> SecretWorkerTransitKeyRotated
  SecretWorkerCompleteGeneratedRoot -> SecretWorkerGeneratedRootCompleted

authorizeWorkerStoreMutation
  :: BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> BootstrapStoreMutation
  -> IO (Either String BootstrapStoreMutationPermit)
authorizeWorkerStoreMutation store kubernetes request mutation = do
  now <- realMonotonicNow
  let requestDeadline = deadlineAtOffset now (RemainingDuration (5 * 1000 * 1000))
  clock <- authorityClockNow
  observedStore <- observeBootstrapSessionFence store
  case observedStore of
    Right observation@(BootstrapFenceStoreHeld fence)
      | workerRequestMatchesFence request fence -> do
          lease <- kubernetesObserveBootstrapLease kubernetes requestDeadline
          pure
            ( either
                (Left . show)
                Right
                ( authorizeBootstrapStoreMutation
                    now
                    requestDeadline
                    clock
                    fence
                    observation
                    lease
                    mutation
                )
            )
    Right _ -> pure (Left "Bootstrap worker durable fence is not held")
    Left _ -> pure (Left "Bootstrap worker durable fence is unavailable")

authorizeWorkerVaultEffect
  :: BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> BootstrapVaultEffect
  -> IO (Either String BootstrapVaultEffectPermit)
authorizeWorkerVaultEffect store kubernetes request effect = do
  now <- realMonotonicNow
  let requestDeadline = deadlineAtOffset now (RemainingDuration (5 * 1000 * 1000))
  clock <- authorityClockNow
  observedStore <- observeBootstrapSessionFence store
  case observedStore of
    Right observation@(BootstrapFenceStoreHeld fence)
      | workerRequestMatchesFence request fence -> do
          lease <- kubernetesObserveBootstrapLease kubernetes requestDeadline
          pure
            ( either
                (Left . show)
                Right
                ( authorizeBootstrapVaultEffect
                    now
                    requestDeadline
                    clock
                    fence
                    observation
                    lease
                    effect
                )
            )
    Right _ -> pure (Left "Bootstrap worker durable fence is not held")
    Left _ -> pure (Left "Bootstrap worker durable fence is unavailable")

workerRequestMatchesFence
  :: SecretFreeWorkerRequest
  -> BootstrapSessionFence
  -> Bool
workerRequestMatchesFence request fence =
  secretWorkerRequestFenceGeneration request == bootstrapFenceGeneration fence
    && secretWorkerRequestOwnerNonce request == bootstrapFenceOwnerNonce fence
    && secretWorkerRequestActionDigest request == bootstrapFenceActionDigest fence
    && secretWorkerRequestDigest request == bootstrapFenceRequestDigest fence
    && secretWorkerRequestStorageGeneration request == bootstrapFenceStorageGeneration fence
    && secretWorkerRequestOperationDeadline request == bootstrapFenceOperationDeadline fence

exactRootBinding
  :: BootstrapStoreBoundary IO
  -> SecretFreeWorkerRequest
  -> IO (Either String RootInitBinding)
exactRootBinding store request = do
  observed <- observeVaultStorageGeneration store
  pure $ case observed of
    Right binding
      | rootInitStorageGeneration binding == secretWorkerRequestStorageGeneration request ->
          Right binding
      | otherwise -> Left "Worker request storage generation does not match the durable binding"
    Left _ -> Left "Durable Vault storage generation is unavailable"

loadPreparedEnvelope
  :: BootstrapStoreBoundary IO
  -> RootInitBinding
  -> IO (Either String PreparedInitEnvelope)
loadPreparedEnvelope store binding = do
  observed <- readPreparedInitEnvelope store binding
  pure (requirePresent "Prepared initialization envelope" observed)

loadEncryptedResponse
  :: BootstrapStoreBoundary IO
  -> RootInitBinding
  -> IO (Either String EncryptedInitResponseReceipt)
loadEncryptedResponse store binding = do
  observed <- readEncryptedInitResponse store binding
  pure (requirePresent "Encrypted initialization response" observed)

loadFinalBundle
  :: BootstrapStoreBoundary IO
  -> RootInitBinding
  -> IO (Either String (StoreVersion, FinalUnlockBundle))
loadFinalBundle store binding = do
  observed <- readFinalUnlockBundle store binding
  pure $ case observed of
    Right (StoreObjectPresent version _ value)
      | finalUnlockBundleBinding value == binding -> Right (version, value)
      | otherwise -> Left "Final unlock bundle binding mismatch"
    Right StoreObjectAbsent -> Left "Final unlock bundle is absent"
    Left _ -> Left "Final unlock bundle is unavailable"

resumeRecipients
  :: BootstrapBrokerSettings
  -> SecretPayload
  -> PreparedInitEnvelope
  -> IO (Either String PreparedInitRecipients)
resumeRecipients settings payload envelope = do
  verified <- verifyCompiledBurnRecipient productionPgpBoundary (brokerBurnRecipient settings)
  case verified of
    Left _ -> pure (Left "Compiled burn recipient verification failed")
    Right burn -> do
      resumed <-
        resumePreparedInitRecipients productionPgpBoundary payload envelope burn
      pure (either (const (Left "Prepared recovery recipient resumption failed")) Right resumed)

encryptedReceipt
  :: PreparedInitEnvelope
  -> EncryptedVaultInitResponse
  -> Either String EncryptedInitResponseReceipt
encryptedReceipt envelope response =
  either
    (Left . show)
    Right
    ( mkEncryptedInitResponseReceipt
        envelope
        (encryptedVaultInitShares response)
        (encryptedVaultInitBurnToken response)
        ( digestSerialised
            ( encryptedVaultInitShares response
            , encryptedVaultInitBurnToken response
            )
        )
    )

submitUnsealShares
  :: BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> SecretFreeWorkerRequest
  -> Vault.VaultAddress
  -> [RecoveredUnsealShare]
  -> IO (Either String Bool)
submitUnsealShares store kubernetes request address shares = do
  initial <- authorizedUnsealCall (Vault.vaultSealStatus address)
  case initial of
    Left _ -> pure (Left "Vault seal status is unavailable")
    Right status
      | not (Vault.sealStatusInitialized status) ->
          pure (Left "Vault is not initialized")
      | not (Vault.sealStatusSealed status) -> pure (Right False)
      | otherwise -> go shares
 where
  go [] = pure (Left "Recovery shares were exhausted before Vault unsealed")
  go (share : rest) =
    withRecoveredUnsealShareBytes share (submitRecoveredShare rest)
  submitRecoveredShare rest bytes =
    case TextEncoding.decodeUtf8' bytes of
      Left _ -> pure (Left "A recovered Vault share was not UTF-8")
      Right key -> do
        submitted <- authorizedUnsealCall (Vault.vaultSubmitUnseal address key)
        case submitted of
          Left _ -> pure (Left "Vault refused a recovered unseal share")
          Right status
            | Vault.sealStatusSealed status -> go rest
            | otherwise -> pure (Right True)

  authorizedUnsealCall action = do
    authorized <-
      authorizeWorkerVaultEffect
        store
        kubernetes
        request
        BootstrapVaultSubmitUnsealShare
    case authorized of
      Left failure -> pure (Left failure)
      Right _ -> mapVaultFailure "Vault unseal call failed" <$> action

mapVaultFailure :: String -> Either error value -> Either String value
mapVaultFailure detail = either (const (Left detail)) Right

requirePresent
  :: String
  -> Either error (StoreReadBack value)
  -> Either String value
requirePresent label observed = case observed of
  Right (StoreObjectPresent _ _ value) -> Right value
  Right StoreObjectAbsent -> Left (label ++ " is absent")
  Left _ -> Left (label ++ " is unavailable")

data UnlockRotationIngress = UnlockRotationIngress
  { unlockRotationCurrentPassword :: !Text
  , unlockRotationNewPassword :: !Text
  }

instance FromJSON UnlockRotationIngress where
  parseJSON = withObject "unlock rotation ingress" $ \value -> do
    schema <- value .: "schema_version"
    if (schema :: Natural) /= 1
      then fail "unsupported unlock rotation schema"
      else do
        current <- value .: "current_password"
        replacement <- value .: "new_password"
        if Text.null current || Text.null replacement || current == replacement
          then fail "unlock rotation passwords are invalid"
          else pure (UnlockRotationIngress current replacement)

vaultAddress :: BootstrapBrokerSettings -> Vault.VaultAddress
vaultAddress = Vault.VaultAddress . brokerVaultAddress

shortDeadline :: IO Deadline
shortDeadline = do
  now <- realMonotonicNow
  pure (deadlineAtOffset now (RemainingDuration (5 * 1000 * 1000)))

authorityClockNow :: IO AuthorityClockObservation
authorityClockNow = do
  seconds <- getPOSIXTime
  let micros :: Natural
      micros = max 0 (floor (seconds * 1000000))
  pure
    ( AuthorityTimeTrusted
        (authorityTimeFromMicros micros)
        (clockUncertaintyFromMicros 1000)
    )

digestSerialised :: (Serialise value) => value -> ArtifactDigest
digestSerialised value = digestBytes (LazyByteString.toStrict (serialise value))

digestBytes :: ByteString -> ArtifactDigest
digestBytes bytes =
  case mkArtifactDigest (lowerHexBytes (SHA256.hash bytes)) of
    Right digest -> digest
    Left failure -> error (show failure)

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap twoHex . ByteString.unpack
 where
  twoHex byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

failWorker :: String -> IO ExitCode
failWorker message = do
  writeDiagnosticLine message
  pure (ExitFailure 1)
