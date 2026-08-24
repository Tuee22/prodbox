{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Native OpenPGP and password-AEAD primitives used inside an attested
-- one-shot Bootstrap Broker worker.  Every GnuPG home is created below
-- @/dev/shm@ and removed by a bracket; private keys and recovered shares are
-- never written to a persistent filesystem.
module Prodbox.Bootstrap.Broker.ProductionPgp
  ( productionPgpCustodyPrimitive
  , productionPgpBoundary
  , productionPgpBoundaryAt
  , productionPgpReady
  , openFinalUnlockPayload
  , classifyVaultCoreReconcileFailure
  , classifyVaultPkiReconcileFailure
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (finally)
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Model
  ( RootSessionBinding (..)
  , rootSessionStorageGeneration
  )
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( GeneratedChildRecoveryAction (..)
  , GeneratedChildRecoveryPrimitiveBoundary
  , GeneratedRootAction (..)
  , GeneratedRootPrimitiveBoundary
  , PgpBoundary
  , PgpBoundaryError (..)
  , PgpCustodyPrimitiveBoundary (..)
  , VerifiedBurnRecipient
  , mkGeneratedChildRecoveryPrimitiveBoundary
  , mkGeneratedRootPrimitiveBoundary
  , mkPgpBoundary
  , verifiedBurnRecipientFingerprint
  , verifiedBurnRecipientPublicKeyDigest
  )
import Prodbox.Bootstrap.Broker.PgpBoundary qualified as Pgp
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , BootstrapSchemaVersion
  , BurnRecipientFingerprint
  , EncryptedInitResponseReceipt
  , FinalUnlockBundlePayload
  , PreparedInitEnvelope
  , PristineStorageProof
  , RecoveryRecipientFingerprint
  , encryptedResponseShares
  , finalPayloadBinding
  , initRecipientBurnFingerprint
  , initRecipientBurnPublicKeyDigest
  , initRecipientRecoveryPublicKeysBase64
  , mkArtifactDigest
  , mkBaselineReadBackReceipt
  , mkBurnRecipientFingerprint
  , mkChildRecoveryRepairReceipt
  , mkInitRecipientCommitment
  , mkPreparedInitEnvelope
  , mkRecoveryRecipientFingerprint
  , mkRootPolicyAccessor
  , mkSealedRecoveryRecipientPrivateKey
  , pgpEncryptedShareCiphertext
  , preparedInitBinding
  , preparedInitEnvelopeDigest
  , preparedInitPristineObservationDigest
  , preparedInitRecipientCommitment
  , preparedInitSealedRecoveryPrivateKey
  , pristineStorageBinding
  , pristineStorageObservationDigest
  , requiredRootBaselineTargets
  , sealedRecoveryRecipientPrivateKeyCiphertext
  )
import Prodbox.Bootstrap.Broker.Types qualified as Types
import Prodbox.Crypto.Aead (aeadNonceBytes, openAead, sealAead)
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Secret.VaultInventory qualified as VaultInventory
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Vault.Client qualified as Vault
import Prodbox.Vault.Reconcile
  ( VaultPkiBaselineStatus (..)
  , VaultPkiObserveError (..)
  , VaultPkiObserveOperation (..)
  , VaultPkiReconcileError (..)
  , VaultPkiReconcileOperation (..)
  , VaultReconcileError (..)
  , VaultReconcileHttpOperation (..)
  , defaultVaultReconcilePlan
  , observeVaultPkiBaseline
  , reconcileVaultPkiBaseline
  , runVaultReconcile
  )
import Prodbox.Vault.UnlockBundle (bootstrapKdfOptions, deriveKey)
import System.Directory (doesDirectoryExist, findExecutable)
import System.Exit (ExitCode (..))
import System.IO.Temp (withTempDirectory)

data PasswordEnvelope = PasswordEnvelope
  { passwordEnvelopeSchema :: !Int
  , passwordEnvelopeSalt :: !ByteString
  , passwordEnvelopeNonce :: !ByteString
  , passwordEnvelopeCiphertext :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

productionPgpReady :: IO Bool
productionPgpReady = do
  gpg <- findExecutable "gpg"
  memoryHome <- doesDirectoryExist "/dev/shm"
  pure (memoryHome && maybe False (const True) gpg)

productionPgpCustodyPrimitive :: PgpCustodyPrimitiveBoundary IO
productionPgpCustodyPrimitive =
  PgpCustodyPrimitiveBoundary
    { primitiveVerifyCompiledBurnRecipient = verifyBurnRecipient
    , primitivePrepareRecoveryRecipient = prepareRecipient
    , primitiveResumePreparedInitRecipients = resumeRecipient
    , primitiveDecryptRecoveryShares = decryptShares
    , primitiveSealFinalUnlockPayload = sealFinalPayload
    }

-- | Complete high-level custody port. Generated-root repair is kept in a
-- distinct primitive family; until a generated-token Vault runner is supplied
-- those callbacks refuse before decrypting ciphertext, while every
-- password-bearing init/unseal primitive is fully installed.
productionPgpBoundary :: PgpBoundary IO
productionPgpBoundary =
  mkPgpBoundary
    productionPgpCustodyPrimitive
    ( mkGeneratedRootPrimitiveBoundary
        (\_ -> pure (Left PgpGeneratedRootTokenRejected))
    )
    ( mkGeneratedChildRecoveryPrimitiveBoundary
        (\_ -> pure (Left PgpGeneratedRootTokenRejected))
    )

-- | Production generated-root interpreter. The GPG private key and decrypted
-- token live only inside the callback bracket; the only token-consuming
-- surface is the closed action GADT from 'PgpBoundary'.
productionPgpBoundaryAt :: Vault.VaultAddress -> PgpBoundary IO
productionPgpBoundaryAt address =
  mkPgpBoundary
    productionPgpCustodyPrimitive
    (productionGeneratedRootPrimitive address)
    (productionGeneratedChildRecoveryPrimitive address)

productionGeneratedRootPrimitive
  :: Vault.VaultAddress -> GeneratedRootPrimitiveBoundary IO
productionGeneratedRootPrimitive address =
  mkGeneratedRootPrimitiveBoundary $ \consume ->
    withMemoryGpgHome $ \home -> do
      generated <- generateRecoveryKey home
      case generated of
        Left failure -> pure (Left failure)
        Right (_, publicBytes, _) ->
          consume
            (TextEncoding.decodeUtf8 (Base64.encode publicBytes))
            (runGeneratedRootSession address home)

runGeneratedRootSession
  :: Vault.VaultAddress
  -> FilePath
  -> ByteString
  -> ( ( forall actionResult
          . GeneratedRootAction actionResult
         -> IO (Either PgpBoundaryError actionResult)
       )
       -> IO (Either PgpBoundaryError result)
     )
  -> IO (Either PgpBoundaryError result)
runGeneratedRootSession address home ciphertext consume = do
  decrypted <- runGpg home ["--decrypt"] ciphertext
  case decrypted >>= generatedVaultToken of
    Left failure -> pure (Left failure)
    Right token -> do
      live <- newIORef True
      consume (runGeneratedRootAction address live token)
        `finally` writeIORef live False

runGeneratedRootAction
  :: Vault.VaultAddress
  -> IORef Bool
  -> Vault.VaultToken
  -> GeneratedRootAction result
  -> IO (Either PgpBoundaryError result)
runGeneratedRootAction address live token action = do
  isLive <- readIORef live
  if not isLive
    then pure (Left PgpGeneratedRootSessionClosed)
    else case action of
      GeneratedRootObserveAccessor _ _ -> do
        observed <- Vault.vaultLookupSelfAccessor address token
        pure $ do
          raw <-
            mapActionFailure
              action
              Pgp.GeneratedRootObserveAccessorRequest
              observed
          mapValueError
            (rootActionRefused action Pgp.GeneratedRootObserveAccessorDecode)
            (mkRootPolicyAccessor raw)
      GeneratedRootApplyAllowlistedBaseline {} -> do
        applied <- runVaultReconcile address token defaultVaultReconcilePlan
        case mapCoreActionFailure
          action
          Pgp.GeneratedRootApplyCoreReconcile
          applied of
          Left failure -> pure (Left failure)
          Right _ -> do
            pki <- reconcileVaultPkiBaseline address token
            pure
              ( mapPkiReconcileActionFailure action pki
                  >> Right ()
              )
      GeneratedRootReadBackAllowlistedBaseline binding _ _ -> do
        observed <- runVaultReconcile address token defaultVaultReconcilePlan
        pki <- observeVaultPkiBaseline address token
        pure $ do
          steps <-
            mapCoreActionFailure
              action
              Pgp.GeneratedRootReadBackCoreReconcile
              observed
          status <-
            mapPkiObserveActionFailure action pki
          case status of
            VaultPkiBaselineReady ->
              mapValueError
                (rootActionRefused action Pgp.GeneratedRootReadBackReceipt)
                ( mkBaselineReadBackReceipt
                    (rootSessionBindingId binding)
                    (rootSessionStorageGeneration binding)
                    requiredRootBaselineTargets
                    (digestArtifact (TextEncoding.encodeUtf8 (Text.pack (show (steps, status)))))
                )
            VaultPkiBaselineAbsent ->
              Left
                ( rootActionRefused
                    action
                    ( Pgp.GeneratedRootReadBackPkiStatus
                        Pgp.GeneratedRootPkiBaselineAbsent
                    )
                )
            VaultPkiBaselineDrifted ->
              Left
                ( rootActionRefused
                    action
                    ( Pgp.GeneratedRootReadBackPkiStatus
                        Pgp.GeneratedRootPkiBaselineDrifted
                    )
                )
      GeneratedRootRevokeAccessor {} -> do
        revoked <- Vault.vaultRevokeSelf address token
        case revoked of
          Left _ ->
            pure
              ( Left
                  (rootActionRefused action Pgp.GeneratedRootRevokeAccessorRequest)
              )
          Right () -> do
            writeIORef live False
            pure (Right ())

productionGeneratedChildRecoveryPrimitive
  :: Vault.VaultAddress -> GeneratedChildRecoveryPrimitiveBoundary IO
productionGeneratedChildRecoveryPrimitive address =
  mkGeneratedChildRecoveryPrimitiveBoundary $ \consume ->
    withMemoryGpgHome $ \home -> do
      generated <- generateRecoveryKey home
      case generated of
        Left failure -> pure (Left failure)
        Right (_, publicBytes, _) ->
          consume
            (TextEncoding.decodeUtf8 (Base64.encode publicBytes))
            (runGeneratedChildRecoverySession address home)

runGeneratedChildRecoverySession
  :: Vault.VaultAddress
  -> FilePath
  -> ByteString
  -> ( ( forall actionResult
          . GeneratedChildRecoveryAction actionResult
         -> IO (Either PgpBoundaryError actionResult)
       )
       -> IO (Either PgpBoundaryError result)
     )
  -> IO (Either PgpBoundaryError result)
runGeneratedChildRecoverySession address home ciphertext consume = do
  decrypted <- runGpg home ["--decrypt"] ciphertext
  case decrypted >>= generatedVaultToken of
    Left failure -> pure (Left failure)
    Right token -> do
      live <- newIORef True
      consume (runGeneratedChildRecoveryAction address live token)
        `finally` writeIORef live False

runGeneratedChildRecoveryAction
  :: Vault.VaultAddress
  -> IORef Bool
  -> Vault.VaultToken
  -> GeneratedChildRecoveryAction result
  -> IO (Either PgpBoundaryError result)
runGeneratedChildRecoveryAction address live token action = do
  isLive <- readIORef live
  if not isLive
    then pure (Left PgpGeneratedChildRecoverySessionClosed)
    else case action of
      GeneratedChildRecoveryObserveAccessor _ _ -> do
        observed <- Vault.vaultLookupSelfAccessor address token
        pure $ do
          raw <- mapChildActionFailure action observed
          mapValueError (childActionRefused action) (mkRootPolicyAccessor raw)
      GeneratedChildRecoveryApplyAllowlistedRepair {} -> do
        applied <- runVaultReconcile address token defaultVaultReconcilePlan
        case mapChildActionFailure action applied of
          Left failure -> pure (Left failure)
          Right _ -> do
            pki <- reconcileVaultPkiBaseline address token
            pure (mapChildActionFailure action pki >> Right ())
      GeneratedChildRecoveryReadBackAllowlistedRepair delivery _ _ -> do
        observed <- runVaultReconcile address token defaultVaultReconcilePlan
        pki <- observeVaultPkiBaseline address token
        pure $ do
          steps <- mapChildActionFailure action observed
          status <- mapChildActionFailure action pki
          if status /= VaultPkiBaselineReady
            then Left (childActionRefused action)
            else
              Right
                ( mkChildRecoveryRepairReceipt
                    delivery
                    (digestArtifact (TextEncoding.encodeUtf8 (Text.pack (show (steps, status)))))
                )
      GeneratedChildRecoveryRevokeAccessor {} -> do
        revoked <- Vault.vaultRevokeSelf address token
        case revoked of
          Left _ -> pure (Left (childActionRefused action))
          Right () -> do
            writeIORef live False
            pure (Right ())

generatedVaultToken :: ByteString -> Either PgpBoundaryError Vault.VaultToken
generatedVaultToken bytes = do
  decoded <-
    either
      (const (Left PgpGeneratedRootTokenRejected))
      Right
      (TextEncoding.decodeUtf8' bytes)
  let token = Text.strip decoded
  if Text.null token || Text.length token > 4096 || Text.any (`elem` [' ', '\t', '\r', '\n']) token
    then Left PgpGeneratedRootTokenRejected
    else Right (Vault.VaultToken token)

rootActionRefused
  :: GeneratedRootAction result
  -> Pgp.GeneratedRootActionFailureStage
  -> PgpBoundaryError
rootActionRefused action =
  PgpGeneratedRootActionRefused (Pgp.generatedRootActionKind action)

mapActionFailure
  :: GeneratedRootAction result
  -> Pgp.GeneratedRootActionFailureStage
  -> Either error value
  -> Either PgpBoundaryError value
mapActionFailure action stage =
  either (const (Left (rootActionRefused action stage))) Right

mapCoreActionFailure
  :: GeneratedRootAction result
  -> ( Pgp.GeneratedRootCoreReconcileCause
       -> Pgp.GeneratedRootActionFailureStage
     )
  -> Either VaultReconcileError value
  -> Either PgpBoundaryError value
mapCoreActionFailure action stage =
  either
    (Left . rootActionRefused action . stage . classifyVaultCoreReconcileFailure)
    Right

mapPkiReconcileActionFailure
  :: GeneratedRootAction result
  -> Either VaultPkiReconcileError value
  -> Either PgpBoundaryError value
mapPkiReconcileActionFailure action =
  either
    ( Left
        . rootActionRefused action
        . Pgp.GeneratedRootApplyPkiReconcile
        . classifyVaultPkiReconcileFailure
    )
    Right

mapPkiObserveActionFailure
  :: GeneratedRootAction result
  -> Either VaultPkiObserveError value
  -> Either PgpBoundaryError value
mapPkiObserveActionFailure action =
  either
    ( Left
        . rootActionRefused action
        . Pgp.GeneratedRootReadBackPkiObserve
        . generatedRootPkiObserveCause
    )
    Right

classifyVaultCoreReconcileFailure
  :: VaultReconcileError -> Pgp.GeneratedRootCoreReconcileCause
classifyVaultCoreReconcileFailure failure = case failure of
  VaultReconcileHttpError operation _ httpFailure ->
    Pgp.GeneratedRootCoreHttpFailure
      (generatedRootCoreHttpOperation operation)
      (generatedRootCoreHttpFailure httpFailure)
  VaultReconcileMountTypeMismatch {} ->
    Pgp.GeneratedRootCoreMountTypeMismatch
  VaultReconcileMountOptionMismatch {} ->
    Pgp.GeneratedRootCoreMountOptionMismatch
  VaultReconcileAuthTypeMismatch {} ->
    Pgp.GeneratedRootCoreAuthTypeMismatch
  VaultReconcileTransitKeyTypeMismatch {} ->
    Pgp.GeneratedRootCoreTransitKeyTypeMismatch
  VaultReconcileKubernetesRoleReadbackMismatch {} ->
    Pgp.GeneratedRootCoreKubernetesRoleReadbackMismatch
  VaultReconcileSecretBootstrapFailed secretFailure ->
    Pgp.GeneratedRootCoreSecretBootstrapFailure
      (generatedRootCoreSecretFailure secretFailure)

generatedRootCoreHttpOperation
  :: VaultReconcileHttpOperation -> Pgp.GeneratedRootCoreHttpOperation
generatedRootCoreHttpOperation operation = case operation of
  VaultReconcileListMounts -> Pgp.GeneratedRootCoreListMounts
  VaultReconcileEnableMount -> Pgp.GeneratedRootCoreEnableMount
  VaultReconcileListAuthMethods -> Pgp.GeneratedRootCoreListAuthMethods
  VaultReconcileEnableAuthMethod -> Pgp.GeneratedRootCoreEnableAuthMethod
  VaultReconcileWriteKubernetesAuthConfig ->
    Pgp.GeneratedRootCoreWriteKubernetesAuthConfig
  VaultReconcileReadTransitKey -> Pgp.GeneratedRootCoreReadTransitKey
  VaultReconcileCreateTransitKey -> Pgp.GeneratedRootCoreCreateTransitKey
  VaultReconcileWritePolicy -> Pgp.GeneratedRootCoreWritePolicy
  VaultReconcileWriteKubernetesRole ->
    Pgp.GeneratedRootCoreWriteKubernetesRole
  VaultReconcileReadBackKubernetesRole ->
    Pgp.GeneratedRootCoreReadBackKubernetesRole

generatedRootCoreHttpFailure :: HttpError -> Pgp.GeneratedRootCoreHttpFailure
generatedRootCoreHttpFailure failure = case failure of
  HttpConnectionFailure _ -> Pgp.GeneratedRootCoreHttpConnectionFailure
  HttpTimeout _ -> Pgp.GeneratedRootCoreHttpTimeout
  HttpStatus status _ -> Pgp.GeneratedRootCoreHttpStatus status
  HttpDecode _ -> Pgp.GeneratedRootCoreHttpDecode

generatedRootCoreSecretFailure
  :: VaultInventory.VaultSecretBootstrapError
  -> Pgp.GeneratedRootCoreSecretFailure
generatedRootCoreSecretFailure failure = case failure of
  VaultInventory.VaultSecretBootstrapReadFailed _ httpFailure ->
    Pgp.GeneratedRootCoreSecretReadFailure
      (generatedRootCoreHttpFailure httpFailure)
  VaultInventory.VaultSecretBootstrapWriteFailed _ writeFailure ->
    case writeFailure of
      Vault.VaultCasApplied _ -> Pgp.GeneratedRootCoreSecretWriteAppliedInvariant
      Vault.VaultCasConflict _ -> Pgp.GeneratedRootCoreSecretWriteConflict
      Vault.VaultCasRefused status _ ->
        Pgp.GeneratedRootCoreSecretWriteRefused status
      Vault.VaultCasUnobservable _ ->
        Pgp.GeneratedRootCoreSecretWriteUnobservable
  VaultInventory.VaultSecretBootstrapExternalFieldMissing {} ->
    Pgp.GeneratedRootCoreSecretExternalFieldMissing

classifyVaultPkiReconcileFailure
  :: VaultPkiReconcileError -> Pgp.GeneratedRootPkiReconcileCause
classifyVaultPkiReconcileFailure failure = case failure of
  VaultPkiReconcileHttpError operation httpFailure ->
    Pgp.GeneratedRootPkiReconcileHttpFailure
      (generatedRootPkiReconcileOperation operation)
      (generatedRootCoreHttpFailure httpFailure)
  VaultPkiReconcileObserveFailed observeFailure ->
    Pgp.GeneratedRootPkiReconcileObserveFailure
      (generatedRootPkiObserveCause observeFailure)
  VaultPkiReconcileReadBackNotExact status ->
    Pgp.GeneratedRootPkiReconcileReadBackNotExact
      (generatedRootPkiBaselineStatus status)

generatedRootPkiReconcileOperation
  :: VaultPkiReconcileOperation -> Pgp.GeneratedRootPkiReconcileOperation
generatedRootPkiReconcileOperation operation = case operation of
  VaultPkiReconcileListIssuers -> Pgp.GeneratedRootPkiReconcileListIssuers
  VaultPkiReconcileGenerateInternalRoot ->
    Pgp.GeneratedRootPkiReconcileGenerateInternalRoot
  VaultPkiReconcileWriteRole -> Pgp.GeneratedRootPkiReconcileWriteRole

generatedRootPkiObserveCause
  :: VaultPkiObserveError -> Pgp.GeneratedRootPkiObserveCause
generatedRootPkiObserveCause failure = case failure of
  VaultPkiObserveHttpError operation httpFailure ->
    Pgp.GeneratedRootPkiObserveHttpFailure
      (generatedRootPkiObserveOperation operation)
      (generatedRootCoreHttpFailure httpFailure)

generatedRootPkiObserveOperation
  :: VaultPkiObserveOperation -> Pgp.GeneratedRootPkiObserveOperation
generatedRootPkiObserveOperation operation = case operation of
  VaultPkiObserveListIssuers -> Pgp.GeneratedRootPkiObserveListIssuers
  VaultPkiObserveReadRole -> Pgp.GeneratedRootPkiObserveReadRole

generatedRootPkiBaselineStatus
  :: VaultPkiBaselineStatus -> Pgp.GeneratedRootPkiBaselineStatus
generatedRootPkiBaselineStatus status = case status of
  VaultPkiBaselineAbsent -> Pgp.GeneratedRootPkiBaselineAbsent
  VaultPkiBaselineDrifted -> Pgp.GeneratedRootPkiBaselineDrifted
  VaultPkiBaselineReady -> Pgp.GeneratedRootPkiBaselineReady

childActionRefused :: Pgp.GeneratedChildRecoveryAction result -> PgpBoundaryError
childActionRefused =
  PgpGeneratedChildRecoveryActionRefused . Pgp.generatedChildRecoveryActionKind

mapChildActionFailure
  :: Pgp.GeneratedChildRecoveryAction result
  -> Either error value
  -> Either PgpBoundaryError value
mapChildActionFailure action =
  either (const (Left (childActionRefused action))) Right

verifyBurnRecipient
  :: Settings.CompiledBurnRecipient
  -> IO (Either PgpBoundaryError (Text, BurnRecipientFingerprint))
verifyBurnRecipient compiled =
  withMemoryGpgHome $ \home -> do
    let encoded = Settings.burnRecipientPublicKeyBase64 compiled
    case Base64.decode (TextEncoding.encodeUtf8 encoded) of
      Left _ -> pure (Left PgpCompiledBurnPublicKeyMismatch)
      Right publicBytes -> do
        imported <- runGpg home ["--import"] publicBytes
        case imported of
          Left failure -> pure (Left failure)
          Right _ -> do
            fingerprint <- observeOpenPgpFingerprint home
            pure $ do
              raw <- fingerprint
              parsed <- mapValueError PgpCompiledBurnRecipientMismatch (mkBurnRecipientFingerprint raw)
              Right (encoded, parsed)

prepareRecipient
  :: ByteString
  -> PristineStorageProof
  -> BootstrapSchemaVersion
  -> VerifiedBurnRecipient
  -> Natural
  -> Natural
  -> ArtifactDigest
  -> IO
       ( Either
           PgpBoundaryError
           (Text, RecoveryRecipientFingerprint, PreparedInitEnvelope)
       )
prepareRecipient passwordBytes pristine schema burn shareCount threshold envelopeDigest =
  withMemoryGpgHome $ \home -> do
    generated <- generateRecoveryKey home
    case generated of
      Left failure -> pure (Left failure)
      Right (fingerprint, publicBytes, privateBytes) -> do
        sealed <-
          sealPasswordBytes
            passwordBytes
            (privateKeyAad pristine envelopeDigest)
            privateBytes
        pure $ do
          sealedPrivate <-
            sealed >>= mapValueError PgpRecipientSealFailed . mkSealedRecoveryRecipientPrivateKey
          recoveryFingerprint <-
            mapValueError
              PgpRecipientGenerationFailed
              (mkRecoveryRecipientFingerprint (digestHex publicBytes))
          let encodedPublic = TextEncoding.decodeUtf8 (Base64.encode publicBytes)
              publicDigest = digestArtifact publicBytes
          commitment <-
            mapValueError
              PgpRecipientGenerationFailed
              ( mkInitRecipientCommitment
                  shareCount
                  threshold
                  (replicate (fromIntegral shareCount) encodedPublic)
                  recoveryFingerprint
                  (verifiedBurnRecipientFingerprint burn)
                  (verifiedBurnRecipientPublicKeyDigest burn)
              )
          let envelope =
                mkPreparedInitEnvelope
                  pristine
                  schema
                  sealedPrivate
                  commitment
                  envelopeDigest
          if Text.null fingerprint || publicDigest /= digestArtifact publicBytes
            then Left PgpRecipientGenerationFailed
            else Right (encodedPublic, recoveryFingerprint, envelope)

resumeRecipient
  :: ByteString
  -> PreparedInitEnvelope
  -> VerifiedBurnRecipient
  -> IO (Either PgpBoundaryError (Text, RecoveryRecipientFingerprint))
resumeRecipient passwordBytes envelope burn =
  withMemoryGpgHome $ \home -> do
    let opened =
          openPasswordBytes
            passwordBytes
            (preparedPrivateKeyAad envelope)
            ( sealedRecoveryRecipientPrivateKeyCiphertext
                (preparedInitSealedRecoveryPrivateKey envelope)
            )
    case opened of
      Left failure -> pure (Left failure)
      Right privateBytes -> do
        imported <- runGpg home ["--import"] privateBytes
        case imported of
          Left failure -> pure (Left failure)
          Right _ -> do
            exported <- exportSolePublicKey home
            pure $ do
              publicBytes <- exported
              let encoded = TextEncoding.decodeUtf8 (Base64.encode publicBytes)
                  commitment = preparedInitRecipientCommitment envelope
              if all (== encoded) (initRecipientRecoveryPublicKeysBase64 commitment)
                && initRecipientBurnFingerprint commitment
                  == verifiedBurnRecipientFingerprint burn
                && initRecipientBurnPublicKeyDigest commitment
                  == verifiedBurnRecipientPublicKeyDigest burn
                then do
                  fingerprint <-
                    mapValueError
                      PgpPreparedRecoveryRecipientMismatch
                      (mkRecoveryRecipientFingerprint (digestHex publicBytes))
                  Right (encoded, fingerprint)
                else Left PgpPreparedRecoveryRecipientMismatch

decryptShares
  :: ByteString
  -> Pgp.PreparedInitRecipients
  -> EncryptedInitResponseReceipt
  -> IO (Either PgpBoundaryError [ByteString])
decryptShares passwordBytes recipients receipt =
  let envelope =
        Pgp.preparedRecoveryEnvelope
          (Pgp.preparedInitRecoveryRecipient recipients)
   in withMemoryGpgHome $ \home -> do
        let opened =
              openPasswordBytes
                passwordBytes
                (preparedPrivateKeyAad envelope)
                ( sealedRecoveryRecipientPrivateKeyCiphertext
                    (preparedInitSealedRecoveryPrivateKey envelope)
                )
        case opened of
          Left failure -> pure (Left failure)
          Right privateBytes -> do
            imported <- runGpg home ["--import"] privateBytes
            case imported of
              Left failure -> pure (Left failure)
              Right _ ->
                traverseGpg
                  (runGpg home ["--decrypt"] . pgpEncryptedShareCiphertext)
                  (encryptedResponseShares receipt)

sealFinalPayload
  :: ByteString
  -> FinalUnlockBundlePayload
  -> IO (Either PgpBoundaryError ByteString)
sealFinalPayload passwordBytes payload =
  sealPasswordBytes
    passwordBytes
    (finalPayloadAad payload)
    (LazyByteString.toStrict (serialise payload))

openFinalUnlockPayload
  :: ByteString
  -> Types.FinalUnlockBundle
  -> Either PgpBoundaryError FinalUnlockBundlePayload
openFinalUnlockPayload passwordBytes bundle = do
  plaintext <-
    openPasswordBytes
      passwordBytes
      ( "prodbox-bootstrap-final-v1:"
          <> LazyByteString.toStrict (serialise (Types.finalUnlockBundleBinding bundle))
      )
      (Types.passwordAeadCiphertextValue (Types.finalUnlockBundleCiphertext bundle))
  decoded <-
    either
      (const (Left PgpPasswordAeadFailed))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict plaintext))
  if finalPayloadBinding decoded == Types.finalUnlockBundleBinding bundle
    then Right decoded
    else Left PgpPasswordAeadFailed

generateRecoveryKey
  :: FilePath
  -> IO (Either PgpBoundaryError (Text, ByteString, ByteString))
generateRecoveryKey home = do
  generated <-
    runGpg
      home
      [ "--pinentry-mode"
      , "loopback"
      , "--passphrase"
      , ""
      , "--quick-generate-key"
      , "Prodbox Ephemeral Recovery <recovery@prodbox.invalid>"
      , "rsa2048"
      , "encr"
      , "0"
      ]
      ByteString.empty
  case generated of
    Left failure -> pure (Left failure)
    Right _ -> do
      fingerprint <- observeOpenPgpFingerprint home
      case fingerprint of
        Left failure -> pure (Left failure)
        Right fpr -> do
          publicBytes <- runGpg home ["--export", Text.unpack fpr] ByteString.empty
          privateBytes <-
            runGpg
              home
              [ "--pinentry-mode"
              , "loopback"
              , "--passphrase"
              , ""
              , "--export-secret-keys"
              , Text.unpack fpr
              ]
              ByteString.empty
          pure ((,,) fpr <$> publicBytes <*> privateBytes)

exportSolePublicKey :: FilePath -> IO (Either PgpBoundaryError ByteString)
exportSolePublicKey home = do
  fingerprint <- observeOpenPgpFingerprint home
  case fingerprint of
    Left failure -> pure (Left failure)
    Right fpr -> runGpg home ["--export", Text.unpack fpr] ByteString.empty

observeOpenPgpFingerprint :: FilePath -> IO (Either PgpBoundaryError Text)
observeOpenPgpFingerprint home = do
  observed <- runGpg home ["--with-colons", "--fingerprint", "--list-keys"] ByteString.empty
  pure $ do
    bytes <- observed
    let fields = fmap (Text.splitOn ":") (Text.lines (TextEncoding.decodeUtf8 bytes))
        fingerprints = [value | row <- fields, take 1 row == ["fpr"], value <- take 1 (drop 9 row)]
    case find (\value -> Text.length value == 40 && Text.all isLowerHex (Text.toLower value)) fingerprints of
      Nothing -> Left PgpRecipientGenerationFailed
      Just value -> Right (Text.toLower value)

runGpg
  :: FilePath
  -> [String]
  -> ByteString
  -> IO (Either PgpBoundaryError ByteString)
runGpg home arguments input = do
  result <-
    captureSubprocessWithInputBounded
      gpgLimits
      input
      Subprocess
        { subprocessPath = "/usr/bin/gpg"
        , subprocessArguments = ["--batch", "--no-tty", "--homedir", home] ++ arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just home
        }
  pure $ case result of
    Left _ -> Left PgpRecipientGenerationFailed
    Right output -> case processExitCode output of
      ExitSuccess -> Right (ByteString8.pack (processStdout output))
      ExitFailure _ -> Left PgpRecipientGenerationFailed

gpgLimits :: BoundedSubprocessLimits
gpgLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 4 * 1024 * 1024
    , boundedSubprocessMaximumStdoutBytes = 4 * 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 64 * 1024
    , boundedSubprocessTimeoutMicros = 2 * 60 * 1000 * 1000
    }

withMemoryGpgHome
  :: (FilePath -> IO (Either PgpBoundaryError value))
  -> IO (Either PgpBoundaryError value)
withMemoryGpgHome = withTempDirectory "/dev/shm" "prodbox-bootstrap-pgp-"

sealPasswordBytes
  :: ByteString
  -> ByteString
  -> ByteString
  -> IO (Either PgpBoundaryError ByteString)
sealPasswordBytes passwordBytes aad plaintext = do
  salt <- getRandomBytes 16
  nonce <- getRandomBytes aeadNonceBytes
  pure $ do
    password <- decodePassword passwordBytes
    key <- mapCryptoError (deriveKey bootstrapKdfOptions password salt)
    ciphertext <- mapCryptoError (sealAead (ByteArray.convert key) nonce aad plaintext)
    Right
      ( LazyByteString.toStrict
          (serialise (PasswordEnvelope 1 salt nonce ciphertext))
      )

openPasswordBytes
  :: ByteString
  -> ByteString
  -> ByteString
  -> Either PgpBoundaryError ByteString
openPasswordBytes passwordBytes aad encoded = do
  password <- decodePassword passwordBytes
  envelope <-
    either
      (const (Left PgpPasswordAeadFailed))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict encoded))
  if passwordEnvelopeSchema envelope /= 1
    then Left PgpPasswordAeadFailed
    else do
      key <-
        mapCryptoError
          (deriveKey bootstrapKdfOptions password (passwordEnvelopeSalt envelope))
      mapCryptoError
        ( openAead
            (ByteArray.convert key)
            (passwordEnvelopeNonce envelope)
            aad
            (passwordEnvelopeCiphertext envelope)
        )

privateKeyAad :: PristineStorageProof -> ArtifactDigest -> ByteString
privateKeyAad proof envelopeDigest =
  "prodbox-bootstrap-recovery-private-v1:"
    <> LazyByteString.toStrict
      ( serialise
          ( pristineStorageBinding proof
          , pristineStorageObservationDigest proof
          , envelopeDigest
          )
      )

preparedPrivateKeyAad :: PreparedInitEnvelope -> ByteString
preparedPrivateKeyAad envelope =
  "prodbox-bootstrap-recovery-private-v1:"
    <> LazyByteString.toStrict
      ( serialise
          ( preparedInitBinding envelope
          , preparedInitPristineObservationDigest envelope
          , preparedInitEnvelopeDigest envelope
          )
      )

finalPayloadAad :: FinalUnlockBundlePayload -> ByteString
finalPayloadAad payload =
  "prodbox-bootstrap-final-v1:"
    <> LazyByteString.toStrict (serialise (finalPayloadBinding payload))

decodePassword :: ByteString -> Either PgpBoundaryError Text
decodePassword = either (const (Left PgpPasswordAeadFailed)) Right . TextEncoding.decodeUtf8'

digestArtifact :: ByteString -> ArtifactDigest
digestArtifact bytes =
  case mkArtifactDigest (digestHex bytes) of
    Right digest -> digest
    Left _ -> error "SHA-256 hex invariant failed"

digestHex :: ByteString -> Text
digestHex = lowerHexBytes . SHA256.hash

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap twoHex . ByteString.unpack
 where
  twoHex byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

isLowerHex :: Char -> Bool
isLowerHex value =
  (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')

traverseGpg
  :: (input -> IO (Either PgpBoundaryError output))
  -> [input]
  -> IO (Either PgpBoundaryError [output])
traverseGpg _ [] = pure (Right [])
traverseGpg action (value : rest) = do
  current <- action value
  case current of
    Left failure -> pure (Left failure)
    Right output -> fmap (fmap (output :)) (traverseGpg action rest)

mapValueError
  :: PgpBoundaryError
  -> Either error value
  -> Either PgpBoundaryError value
mapValueError failure = either (const (Left failure)) Right

mapCryptoError :: Either error value -> Either PgpBoundaryError value
mapCryptoError = either (const (Left PgpPasswordAeadFailed)) Right
