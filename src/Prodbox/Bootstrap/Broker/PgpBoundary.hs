{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RankNTypes #-}

-- | Typed OpenPGP/AEAD boundary for bootstrap custody.  This module specifies
-- the cryptographic effects without pretending that an offline fake performs
-- OpenPGP.  Recipient constructors validate canonical wire encodings while
-- the opaque evidence types bind the exact prepared envelope to the exact
-- recovery and compiled burn public keys.
--
-- Deliberately absent: any operation that decrypts the burn-recipient initial
-- token.  The compiled burn identity has no private-key type anywhere in this
-- API.
module Prodbox.Bootstrap.Broker.PgpBoundary
  ( PgpBoundaryError (..)
  , RecoveryRecipientPublicKey
  , mkRecoveryRecipientPublicKey
  , recoveryRecipientPublicKeyBase64
  , recoveryRecipientPublicKeyDigest
  , BurnRecipientPublicKey
  , mkBurnRecipientPublicKey
  , burnRecipientPublicKeyBase64
  , burnRecipientPublicKeyDigest
  , VerifiedBurnRecipient
  , mkVerifiedBurnRecipient
  , verifiedBurnRecipientPublicKey
  , verifiedBurnRecipientFingerprint
  , verifiedBurnRecipientPublicKeyDigest
  , PreparedRecoveryRecipient
  , preparedRecoveryPublicKey
  , preparedRecoveryEnvelope
  , PreparedInitRecipients
  , preparedInitRecoveryRecipient
  , preparedInitVerifiedBurnRecipient
  , preparedInitRecipientShareCount
  , preparedInitRecipientThreshold
  , preparedInitRecoveryPublicKeysBase64
  , preparedInitBurnPublicKeyBase64
  , GeneratedRootPublicKey
  , mkGeneratedRootPublicKey
  , generatedRootPublicKeyBase64
  , GeneratedRootCiphertext
  , mkGeneratedRootCiphertext
  , GeneratedChildRecoveryPublicKey
  , mkGeneratedChildRecoveryPublicKey
  , generatedChildRecoveryPublicKeyBase64
  , GeneratedChildRecoveryCiphertext
  , mkGeneratedChildRecoveryCiphertext
  , GeneratedRootAction (..)
  , GeneratedRootActionKind (..)
  , allGeneratedRootActionKinds
  , generatedRootActionKind
  , GeneratedRootWorkflow (..)
  , GeneratedChildRecoveryAction (..)
  , GeneratedChildRecoveryActionKind (..)
  , allGeneratedChildRecoveryActionKinds
  , generatedChildRecoveryActionKind
  , GeneratedChildRecoveryWorkflow (..)
  , GeneratedRootPrimitiveBoundary
  , mkGeneratedRootPrimitiveBoundary
  , GeneratedChildRecoveryPrimitiveBoundary
  , mkGeneratedChildRecoveryPrimitiveBoundary
  , withGeneratedRootRecipientFromPrimitive
  , withGeneratedChildRecoveryRecipientFromPrimitive
  , PgpCustodyPrimitiveBoundary (..)
  , PgpBoundary
  , mkPgpBoundary
  , verifyCompiledBurnRecipient
  , prepareRecoveryRecipient
  , resumePreparedInitRecipients
  , decryptRecoveryShares
  , sealFinalUnlockPayload
  , withGeneratedRootRecipient
  , withGeneratedChildRecoveryRecipient
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapVaultEffect (..)
  , BootstrapVaultEffectPermit
  , vaultEffectPermitActionDigest
  , vaultEffectPermitEffect
  , vaultEffectPermitFenceGeneration
  , vaultEffectPermitOperationDeadline
  , vaultEffectPermitOwnerNonce
  , vaultEffectPermitRequestDigest
  , vaultEffectPermitStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Model
  ( RootSessionBinding
  , rootSessionStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Request (SecretPayload)
import Prodbox.Bootstrap.Broker.Request.Internal qualified as RequestInternal
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , BaselineReadBackReceipt
  , BootstrapSchemaVersion
  , BurnRecipientFingerprint
  , ChildRecoveryDelivery
  , ChildRecoveryRepairReceipt
  , EncryptedInitResponseReceipt
  , FinalUnlockBundlePayload
  , PasswordAeadCiphertext
  , PreparedInitEnvelope
  , PristineStorageProof
  , RecoveredUnsealShare
  , RecoveryRecipientFingerprint
  , RootPolicyAccessor
  , childCustodyStorageGeneration
  , childRecoveryDeliveryBinding
  , initRecipientBurnFingerprint
  , initRecipientBurnPublicKeyDigest
  , initRecipientRecoveryPublicKeysBase64
  , initRecipientShareCount
  , initRecipientThreshold
  , mkArtifactDigest
  , mkPasswordAeadCiphertext
  , mkRecoveredUnsealShare
  , preparedInitBinding
  , preparedInitEnvelopeDigest
  , preparedInitPristineObservationDigest
  , preparedInitRecipientCommitment
  , preparedInitRecoveryFingerprint
  , preparedInitSchemaVersion
  , pristineStorageBinding
  , pristineStorageObservationDigest
  , renderArtifactDigest
  , renderBurnRecipientFingerprint
  )

data PgpBoundaryError
  = PgpCompiledBurnRecipientMismatch
  | PgpCompiledBurnPublicKeyMismatch
  | PgpCompiledBurnPublicKeyDigestMismatch
  | PgpRecipientGenerationFailed
  | PgpRecipientSealFailed
  | PgpRecipientPublicKeyNotCanonicalBase64
  | PgpPreparedRecoveryRecipientMismatch
  | PgpPreparedBurnRecipientMismatch
  | PgpEncryptedShareRejected
  | PgpGeneratedRootCiphertextRejected
  | PgpGeneratedChildRecoveryCiphertextRejected
  | PgpGeneratedRootSessionClosed
  | PgpGeneratedRootSessionPermitMismatch
      !BootstrapVaultEffect
      !BootstrapVaultEffect
  | PgpGeneratedRootSessionGenerationMismatch
  | PgpGeneratedRootActionRefused
  | PgpGeneratedRootActionPermitMismatch
      !BootstrapVaultEffect
      !BootstrapVaultEffect
  | PgpGeneratedRootActionGenerationMismatch
  | PgpGeneratedRootActionBindingMismatch
  | PgpGeneratedRootActionFenceIdentityMismatch
  | PgpGeneratedChildRecoverySessionClosed
  | PgpGeneratedChildRecoverySessionPermitMismatch
      !BootstrapVaultEffect
      !BootstrapVaultEffect
  | PgpGeneratedChildRecoverySessionGenerationMismatch
  | PgpGeneratedChildRecoveryActionPermitMismatch
      !BootstrapVaultEffect
      !BootstrapVaultEffect
  | PgpGeneratedChildRecoveryActionBindingMismatch
  | PgpGeneratedChildRecoveryActionGenerationMismatch
  | PgpGeneratedChildRecoveryActionFenceIdentityMismatch
  | PgpPasswordAeadFailed
  deriving (Eq, Show)

data RecoveryRecipientPublicKey = RecoveryRecipientPublicKey !Text !ArtifactDigest
  deriving (Eq)

instance Show RecoveryRecipientPublicKey where
  show _ = "RecoveryRecipientPublicKey <public>"

recoveryRecipientPublicKeyBase64 :: RecoveryRecipientPublicKey -> Text
recoveryRecipientPublicKeyBase64 (RecoveryRecipientPublicKey encoded _) = encoded

mkRecoveryRecipientPublicKey :: Text -> Either PgpBoundaryError RecoveryRecipientPublicKey
mkRecoveryRecipientPublicKey encoded = do
  canonical <- validatePublicKeyBase64 encoded
  digest <- digestPublicKey canonical
  Right (RecoveryRecipientPublicKey canonical digest)

recoveryRecipientPublicKeyDigest :: RecoveryRecipientPublicKey -> ArtifactDigest
recoveryRecipientPublicKeyDigest (RecoveryRecipientPublicKey _ digest) = digest

data BurnRecipientPublicKey = BurnRecipientPublicKey !Text !ArtifactDigest
  deriving (Eq)

instance Show BurnRecipientPublicKey where
  show _ = "BurnRecipientPublicKey <public>"

burnRecipientPublicKeyBase64 :: BurnRecipientPublicKey -> Text
burnRecipientPublicKeyBase64 (BurnRecipientPublicKey encoded _) = encoded

mkBurnRecipientPublicKey :: Text -> Either PgpBoundaryError BurnRecipientPublicKey
mkBurnRecipientPublicKey encoded = do
  canonical <- validatePublicKeyBase64 encoded
  digest <- digestPublicKey canonical
  Right (BurnRecipientPublicKey canonical digest)

burnRecipientPublicKeyDigest :: BurnRecipientPublicKey -> ArtifactDigest
burnRecipientPublicKeyDigest (BurnRecipientPublicKey _ digest) = digest

-- | Evidence that a concrete public key matches both compile-time burn pins.
-- The SHA-256 digest is recomputed from the canonical decoded public-key
-- bytes; callers cannot substitute an arbitrary key while copying the pins.
data VerifiedBurnRecipient
  = VerifiedBurnRecipient
      !BurnRecipientPublicKey
      !BurnRecipientFingerprint
      !ArtifactDigest
  deriving (Eq, Show)

mkVerifiedBurnRecipient
  :: Settings.CompiledBurnRecipient
  -> BurnRecipientPublicKey
  -> BurnRecipientFingerprint
  -> Either PgpBoundaryError VerifiedBurnRecipient
mkVerifiedBurnRecipient compiled publicKey observedFingerprint
  | observedPublicKey /= expectedPublicKey =
      Left PgpCompiledBurnPublicKeyMismatch
  | Text.toCaseFold expectedFingerprint
      /= Text.toCaseFold (renderBurnRecipientFingerprint observedFingerprint) =
      Left PgpCompiledBurnRecipientMismatch
  | expectedDigest /= renderArtifactDigest observedDigest =
      Left PgpCompiledBurnPublicKeyDigestMismatch
  | otherwise =
      Right (VerifiedBurnRecipient publicKey observedFingerprint observedDigest)
 where
  expectedPublicKey = Settings.burnRecipientPublicKeyBase64 compiled
  observedPublicKey = burnRecipientPublicKeyBase64 publicKey
  expectedFingerprint =
    Settings.unBurnRecipientFingerprint
      (Settings.burnRecipientFingerprint compiled)
  expectedDigest =
    fromMaybe
      expectedDigestWithAlgorithm
      (Text.stripPrefix (Text.pack "sha256:") expectedDigestWithAlgorithm)
  expectedDigestWithAlgorithm =
    Text.toLower
      (Settings.unBurnRecipientPublicKeyDigest (Settings.burnRecipientPublicKeyDigest compiled))
  observedDigest = burnRecipientPublicKeyDigest publicKey

verifiedBurnRecipientPublicKey :: VerifiedBurnRecipient -> BurnRecipientPublicKey
verifiedBurnRecipientPublicKey (VerifiedBurnRecipient publicKey _ _) = publicKey

verifiedBurnRecipientFingerprint
  :: VerifiedBurnRecipient -> BurnRecipientFingerprint
verifiedBurnRecipientFingerprint (VerifiedBurnRecipient _ fingerprint _) = fingerprint

verifiedBurnRecipientPublicKeyDigest :: VerifiedBurnRecipient -> ArtifactDigest
verifiedBurnRecipientPublicKeyDigest (VerifiedBurnRecipient _ _ digest) = digest

data PreparedRecoveryRecipient
  = PreparedRecoveryRecipient
      !RecoveryRecipientPublicKey
      !PreparedInitEnvelope
  deriving (Eq, Show)

preparedRecoveryPublicKey
  :: PreparedRecoveryRecipient -> RecoveryRecipientPublicKey
preparedRecoveryPublicKey (PreparedRecoveryRecipient publicKey _) = publicKey

preparedRecoveryEnvelope :: PreparedRecoveryRecipient -> PreparedInitEnvelope
preparedRecoveryEnvelope (PreparedRecoveryRecipient _ envelope) = envelope

-- | Exact target-path input for Vault initialization.  Its constructor is
-- boundary-private: only the cryptographic preparation/resume interpreter in
-- this module may attest that the recovery private/public pair matches the
-- durable envelope and that the burn key matches the compiled pins.
data PreparedInitRecipients
  = PreparedInitRecipients
      !PreparedRecoveryRecipient
      !VerifiedBurnRecipient
  deriving (Eq, Show)

preparedInitRecoveryRecipient
  :: PreparedInitRecipients -> PreparedRecoveryRecipient
preparedInitRecoveryRecipient (PreparedInitRecipients recoveryRecipient _) = recoveryRecipient

preparedInitVerifiedBurnRecipient
  :: PreparedInitRecipients -> VerifiedBurnRecipient
preparedInitVerifiedBurnRecipient (PreparedInitRecipients _ burnRecipient) = burnRecipient

preparedInitRecipientShareCount :: PreparedInitRecipients -> Natural
preparedInitRecipientShareCount =
  initRecipientShareCount
    . preparedInitRecipientCommitment
    . preparedRecoveryEnvelope
    . preparedInitRecoveryRecipient

preparedInitRecipientThreshold :: PreparedInitRecipients -> Natural
preparedInitRecipientThreshold =
  initRecipientThreshold
    . preparedInitRecipientCommitment
    . preparedRecoveryEnvelope
    . preparedInitRecoveryRecipient

preparedInitRecoveryPublicKeysBase64 :: PreparedInitRecipients -> [Text]
preparedInitRecoveryPublicKeysBase64 =
  initRecipientRecoveryPublicKeysBase64
    . preparedInitRecipientCommitment
    . preparedRecoveryEnvelope
    . preparedInitRecoveryRecipient

preparedInitBurnPublicKeyBase64 :: PreparedInitRecipients -> Text
preparedInitBurnPublicKeyBase64 =
  burnRecipientPublicKeyBase64
    . verifiedBurnRecipientPublicKey
    . preparedInitVerifiedBurnRecipient

newtype GeneratedRootPublicKey = GeneratedRootPublicKey Text
  deriving (Eq)

instance Show GeneratedRootPublicKey where
  show _ = "GeneratedRootPublicKey <public>"

generatedRootPublicKeyBase64 :: GeneratedRootPublicKey -> Text
generatedRootPublicKeyBase64 (GeneratedRootPublicKey encoded) = encoded

mkGeneratedRootPublicKey :: Text -> Either PgpBoundaryError GeneratedRootPublicKey
mkGeneratedRootPublicKey encoded =
  GeneratedRootPublicKey <$> validatePublicKeyBase64 encoded

newtype GeneratedRootCiphertext = GeneratedRootCiphertext ByteString
  deriving (Eq)

instance Show GeneratedRootCiphertext where
  show _ = "GeneratedRootCiphertext <redacted>"

mkGeneratedRootCiphertext :: ByteString -> Either PgpBoundaryError GeneratedRootCiphertext
mkGeneratedRootCiphertext bytes
  | BS.null bytes || BS.length bytes > 4 * 1024 * 1024 =
      Left PgpGeneratedRootCiphertextRejected
  | otherwise = Right (GeneratedRootCiphertext bytes)

-- | A child-recovery generate-root recipient is deliberately distinct from a
-- root-baseline recipient.  The wire encoding obeys the same canonical PGP
-- rules, but a caller cannot pass one authority class to the other flow.
newtype GeneratedChildRecoveryPublicKey
  = GeneratedChildRecoveryPublicKey Text
  deriving (Eq)

instance Show GeneratedChildRecoveryPublicKey where
  show _ = "GeneratedChildRecoveryPublicKey <public>"

generatedChildRecoveryPublicKeyBase64
  :: GeneratedChildRecoveryPublicKey -> Text
generatedChildRecoveryPublicKeyBase64 (GeneratedChildRecoveryPublicKey encoded) = encoded

mkGeneratedChildRecoveryPublicKey
  :: Text -> Either PgpBoundaryError GeneratedChildRecoveryPublicKey
mkGeneratedChildRecoveryPublicKey encoded =
  GeneratedChildRecoveryPublicKey <$> validatePublicKeyBase64 encoded

newtype GeneratedChildRecoveryCiphertext
  = GeneratedChildRecoveryCiphertext ByteString
  deriving (Eq)

instance Show GeneratedChildRecoveryCiphertext where
  show _ = "GeneratedChildRecoveryCiphertext <redacted>"

mkGeneratedChildRecoveryCiphertext
  :: ByteString -> Either PgpBoundaryError GeneratedChildRecoveryCiphertext
mkGeneratedChildRecoveryCiphertext bytes
  | BS.null bytes || BS.length bytes > 4 * 1024 * 1024 =
      Left PgpGeneratedChildRecoveryCiphertextRejected
  | otherwise = Right (GeneratedChildRecoveryCiphertext bytes)

-- | The complete vocabulary that may consume a generated-root session token.
-- Every action is bound to the exact durable root session.  There is no raw
-- Vault path, arbitrary request body, token-byte accessor, or generic callback
-- constructor.  Inventory and absence proof are deliberately absent: after
-- revoke-self succeeds this token is invalid, so those observations belong to
-- the separately permitted broker-only accessor auditor.
data GeneratedRootAction result where
  GeneratedRootObserveAccessor
    :: RootSessionBinding
    -> BootstrapVaultEffectPermit
    -> GeneratedRootAction RootPolicyAccessor
  GeneratedRootApplyAllowlistedBaseline
    :: RootSessionBinding
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> GeneratedRootAction ()
  GeneratedRootReadBackAllowlistedBaseline
    :: RootSessionBinding
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> GeneratedRootAction BaselineReadBackReceipt
  GeneratedRootRevokeAccessor
    :: RootSessionBinding
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> GeneratedRootAction ()

-- | Auditable projection of the complete token-consuming action vocabulary.
-- The exact enumeration deliberately ends at revoke-self; post-revocation
-- inventory/absence is not a generated-root-token authority.
data GeneratedRootActionKind
  = GeneratedRootObserveSelfAction
  | GeneratedRootApplyBaselineAction
  | GeneratedRootReadBackBaselineAction
  | GeneratedRootRevokeSelfAction
  deriving (Eq, Ord, Show, Enum, Bounded)

allGeneratedRootActionKinds :: [GeneratedRootActionKind]
allGeneratedRootActionKinds = [minBound .. maxBound]

generatedRootActionKind :: GeneratedRootAction result -> GeneratedRootActionKind
generatedRootActionKind action = case action of
  GeneratedRootObserveAccessor {} -> GeneratedRootObserveSelfAction
  GeneratedRootApplyAllowlistedBaseline {} -> GeneratedRootApplyBaselineAction
  GeneratedRootReadBackAllowlistedBaseline {} -> GeneratedRootReadBackBaselineAction
  GeneratedRootRevokeAccessor {} -> GeneratedRootRevokeSelfAction

-- | Controller hooks for the complete generated-root workflow.  The workflow
-- state belongs to the controller (normally a durable journal version/state
-- pair), but the token and its runner never do.  Each hook commits the crash
-- boundary needed before the next privileged action.
data GeneratedRootWorkflow m workflowError workflowState workflowResult
  = GeneratedRootWorkflow
  { rootWorkflowInitialState :: !workflowState
  , rootWorkflowAuthorize
      :: BootstrapVaultEffect
      -> m (Either workflowError BootstrapVaultEffectPermit)
  , rootWorkflowAfterAccessor
      :: workflowState
      -> RootPolicyAccessor
      -> m (Either workflowError workflowState)
  , rootWorkflowAfterApply
      :: workflowState
      -> m (Either workflowError workflowState)
  , rootWorkflowAfterReadBack
      :: workflowState
      -> BaselineReadBackReceipt
      -> m (Either workflowError workflowState)
  , rootWorkflowAfterRevoke
      :: workflowState
      -> m (Either workflowError workflowResult)
  }

data GeneratedRootSessionEvidence
  = GeneratedRootSessionEvidence
      !RootSessionBinding
      !BootstrapVaultEffectPermit

-- | Execute the only legal token-consuming order.  The raw runner is scoped
-- inside the primitive interpreter's decrypt-and-bracket callback.  Neither it
-- nor plaintext token bytes occur in this function's result type, and revoke
-- is terminal: after it succeeds there is no continuation that can issue a
-- further token action.
runClosedGeneratedRootWorkflow
  :: (Monad m)
  => RootSessionBinding
  -> BootstrapVaultEffectPermit
  -> ( forall actionResult
        . GeneratedRootAction actionResult
       -> m (Either PgpBoundaryError actionResult)
     )
  -> GeneratedRootWorkflow m workflowError workflowState workflowResult
  -> m
       ( Either
           PgpBoundaryError
           (Either workflowError workflowResult)
       )
runClosedGeneratedRootWorkflow binding originatingPermit runRaw workflow =
  case validateGeneratedRootSession binding originatingPermit of
    Left refusal -> pure (Left refusal)
    Right evidence ->
      controllerStep
        (rootWorkflowAuthorize workflow BootstrapVaultObserveGeneratedRootAccessor)
        ( \observePermit ->
            pgpStep
              ( runCheckedGeneratedRootAction
                  evidence
                  runRaw
                  (GeneratedRootObserveAccessor binding observePermit)
              )
              ( \accessor ->
                  controllerStep
                    ( rootWorkflowAfterAccessor
                        workflow
                        (rootWorkflowInitialState workflow)
                        accessor
                    )
                    ( \accessorState ->
                        controllerStep
                          (rootWorkflowAuthorize workflow BootstrapVaultApplyBaseline)
                          ( \applyPermit ->
                              pgpStep
                                ( runCheckedGeneratedRootAction
                                    evidence
                                    runRaw
                                    ( GeneratedRootApplyAllowlistedBaseline
                                        binding
                                        applyPermit
                                        accessor
                                    )
                                )
                                ( \() ->
                                    controllerStep
                                      ( rootWorkflowAfterApply
                                          workflow
                                          accessorState
                                      )
                                      ( \appliedState ->
                                          controllerStep
                                            ( rootWorkflowAuthorize
                                                workflow
                                                BootstrapVaultReadBackBaseline
                                            )
                                            ( \readBackPermit ->
                                                pgpStep
                                                  ( runCheckedGeneratedRootAction
                                                      evidence
                                                      runRaw
                                                      ( GeneratedRootReadBackAllowlistedBaseline
                                                          binding
                                                          readBackPermit
                                                          accessor
                                                      )
                                                  )
                                                  ( \readBack ->
                                                      controllerStep
                                                        ( rootWorkflowAfterReadBack
                                                            workflow
                                                            appliedState
                                                            readBack
                                                        )
                                                        ( \readBackState ->
                                                            controllerStep
                                                              ( rootWorkflowAuthorize
                                                                  workflow
                                                                  BootstrapVaultRevokeRootAccessor
                                                              )
                                                              ( \revokePermit ->
                                                                  pgpStep
                                                                    ( runCheckedGeneratedRootAction
                                                                        evidence
                                                                        runRaw
                                                                        ( GeneratedRootRevokeAccessor
                                                                            binding
                                                                            revokePermit
                                                                            accessor
                                                                        )
                                                                    )
                                                                    ( \() ->
                                                                        controllerTerminal
                                                                          ( rootWorkflowAfterRevoke
                                                                              workflow
                                                                              readBackState
                                                                          )
                                                                    )
                                                              )
                                                        )
                                                  )
                                            )
                                      )
                                )
                          )
                    )
              )
        )

validateGeneratedRootSession
  :: RootSessionBinding
  -> BootstrapVaultEffectPermit
  -> Either PgpBoundaryError GeneratedRootSessionEvidence
validateGeneratedRootSession binding permit
  | observedEffect /= BootstrapVaultSubmitGenerateRootShare =
      Left
        ( PgpGeneratedRootSessionPermitMismatch
            BootstrapVaultSubmitGenerateRootShare
            observedEffect
        )
  | vaultEffectPermitStorageGeneration permit
      /= rootSessionStorageGeneration binding =
      Left PgpGeneratedRootSessionGenerationMismatch
  | otherwise = Right (GeneratedRootSessionEvidence binding permit)
 where
  observedEffect = vaultEffectPermitEffect permit

runCheckedGeneratedRootAction
  :: (Applicative m)
  => GeneratedRootSessionEvidence
  -> ( forall actionResult
        . GeneratedRootAction actionResult
       -> m (Either PgpBoundaryError actionResult)
     )
  -> GeneratedRootAction result
  -> m (Either PgpBoundaryError result)
runCheckedGeneratedRootAction evidence runRaw action =
  case validateGeneratedRootAction evidence action of
    Left refusal -> pure (Left refusal)
    Right () -> runRaw action

validateGeneratedRootAction
  :: GeneratedRootSessionEvidence
  -> GeneratedRootAction actionResult
  -> Either PgpBoundaryError ()
validateGeneratedRootAction
  (GeneratedRootSessionEvidence expectedBinding originatingPermit)
  action
    | binding /= expectedBinding = Left PgpGeneratedRootActionBindingMismatch
    | observedEffect /= expectedEffect =
        Left (PgpGeneratedRootActionPermitMismatch expectedEffect observedEffect)
    | vaultEffectPermitStorageGeneration permit
        /= rootSessionStorageGeneration binding =
        Left PgpGeneratedRootActionGenerationMismatch
    | not (sameFenceIdentity originatingPermit permit) =
        Left PgpGeneratedRootActionFenceIdentityMismatch
    | otherwise = Right ()
   where
    (binding, permit, expectedEffect) = case action of
      GeneratedRootObserveAccessor observedBinding observedPermit ->
        ( observedBinding
        , observedPermit
        , BootstrapVaultObserveGeneratedRootAccessor
        )
      GeneratedRootApplyAllowlistedBaseline observedBinding observedPermit _ ->
        (observedBinding, observedPermit, BootstrapVaultApplyBaseline)
      GeneratedRootReadBackAllowlistedBaseline observedBinding observedPermit _ ->
        (observedBinding, observedPermit, BootstrapVaultReadBackBaseline)
      GeneratedRootRevokeAccessor observedBinding observedPermit _ ->
        (observedBinding, observedPermit, BootstrapVaultRevokeRootAccessor)
    observedEffect = vaultEffectPermitEffect permit

-- | Closed actions available while a generated root token is repairing a
-- child Vault after an exact one-time recovery delivery.  Auditor inventory
-- and absence actions are deliberately outside this token-consuming family.
data GeneratedChildRecoveryAction result where
  GeneratedChildRecoveryObserveAccessor
    :: ChildRecoveryDelivery
    -> BootstrapVaultEffectPermit
    -> GeneratedChildRecoveryAction RootPolicyAccessor
  GeneratedChildRecoveryApplyAllowlistedRepair
    :: ChildRecoveryDelivery
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> GeneratedChildRecoveryAction ()
  GeneratedChildRecoveryReadBackAllowlistedRepair
    :: ChildRecoveryDelivery
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> GeneratedChildRecoveryAction ChildRecoveryRepairReceipt
  GeneratedChildRecoveryRevokeAccessor
    :: ChildRecoveryDelivery
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> GeneratedChildRecoveryAction ()

data GeneratedChildRecoveryActionKind
  = GeneratedChildRecoveryObserveSelfAction
  | GeneratedChildRecoveryApplyRepairAction
  | GeneratedChildRecoveryReadBackRepairAction
  | GeneratedChildRecoveryRevokeSelfAction
  deriving (Eq, Ord, Show, Enum, Bounded)

allGeneratedChildRecoveryActionKinds :: [GeneratedChildRecoveryActionKind]
allGeneratedChildRecoveryActionKinds = [minBound .. maxBound]

generatedChildRecoveryActionKind
  :: GeneratedChildRecoveryAction result
  -> GeneratedChildRecoveryActionKind
generatedChildRecoveryActionKind action = case action of
  GeneratedChildRecoveryObserveAccessor {} ->
    GeneratedChildRecoveryObserveSelfAction
  GeneratedChildRecoveryApplyAllowlistedRepair {} ->
    GeneratedChildRecoveryApplyRepairAction
  GeneratedChildRecoveryReadBackAllowlistedRepair {} ->
    GeneratedChildRecoveryReadBackRepairAction
  GeneratedChildRecoveryRevokeAccessor {} ->
    GeneratedChildRecoveryRevokeSelfAction

-- | Controller hooks for the child-recovery repair workflow.  Root and child
-- workflow types remain nominally distinct, so neither a delivery nor its
-- repair receipt can be routed through the root-baseline fold.
data
  GeneratedChildRecoveryWorkflow
    m
    workflowError
    workflowState
    workflowResult
  = GeneratedChildRecoveryWorkflow
  { childWorkflowInitialState :: !workflowState
  , childWorkflowAuthorize
      :: BootstrapVaultEffect
      -> m (Either workflowError BootstrapVaultEffectPermit)
  , childWorkflowAfterAccessor
      :: workflowState
      -> RootPolicyAccessor
      -> m (Either workflowError workflowState)
  , childWorkflowAfterApply
      :: workflowState
      -> m (Either workflowError workflowState)
  , childWorkflowAfterReadBack
      :: workflowState
      -> ChildRecoveryRepairReceipt
      -> m (Either workflowError workflowState)
  , childWorkflowAfterRevoke
      :: workflowState
      -> m (Either workflowError workflowResult)
  }

data GeneratedChildRecoverySessionEvidence
  = GeneratedChildRecoverySessionEvidence
      !ChildRecoveryDelivery
      !BootstrapVaultEffectPermit

runClosedGeneratedChildRecoveryWorkflow
  :: (Monad m)
  => ChildRecoveryDelivery
  -> BootstrapVaultEffectPermit
  -> ( forall actionResult
        . GeneratedChildRecoveryAction actionResult
       -> m (Either PgpBoundaryError actionResult)
     )
  -> GeneratedChildRecoveryWorkflow
       m
       workflowError
       workflowState
       workflowResult
  -> m
       ( Either
           PgpBoundaryError
           (Either workflowError workflowResult)
       )
runClosedGeneratedChildRecoveryWorkflow delivery originatingPermit runRaw workflow =
  case validateGeneratedChildRecoverySession delivery originatingPermit of
    Left refusal -> pure (Left refusal)
    Right evidence ->
      controllerStep
        (childWorkflowAuthorize workflow BootstrapVaultObserveGeneratedRootAccessor)
        ( \observePermit ->
            pgpStep
              ( runCheckedGeneratedChildRecoveryAction
                  evidence
                  runRaw
                  (GeneratedChildRecoveryObserveAccessor delivery observePermit)
              )
              ( \accessor ->
                  controllerStep
                    ( childWorkflowAfterAccessor
                        workflow
                        (childWorkflowInitialState workflow)
                        accessor
                    )
                    ( \accessorState ->
                        controllerStep
                          (childWorkflowAuthorize workflow BootstrapVaultApplyBaseline)
                          ( \applyPermit ->
                              pgpStep
                                ( runCheckedGeneratedChildRecoveryAction
                                    evidence
                                    runRaw
                                    ( GeneratedChildRecoveryApplyAllowlistedRepair
                                        delivery
                                        applyPermit
                                        accessor
                                    )
                                )
                                ( \() ->
                                    controllerStep
                                      ( childWorkflowAfterApply
                                          workflow
                                          accessorState
                                      )
                                      ( \appliedState ->
                                          controllerStep
                                            ( childWorkflowAuthorize
                                                workflow
                                                BootstrapVaultReadBackBaseline
                                            )
                                            ( \readBackPermit ->
                                                pgpStep
                                                  ( runCheckedGeneratedChildRecoveryAction
                                                      evidence
                                                      runRaw
                                                      ( GeneratedChildRecoveryReadBackAllowlistedRepair
                                                          delivery
                                                          readBackPermit
                                                          accessor
                                                      )
                                                  )
                                                  ( \readBack ->
                                                      controllerStep
                                                        ( childWorkflowAfterReadBack
                                                            workflow
                                                            appliedState
                                                            readBack
                                                        )
                                                        ( \readBackState ->
                                                            controllerStep
                                                              ( childWorkflowAuthorize
                                                                  workflow
                                                                  BootstrapVaultRevokeRootAccessor
                                                              )
                                                              ( \revokePermit ->
                                                                  pgpStep
                                                                    ( runCheckedGeneratedChildRecoveryAction
                                                                        evidence
                                                                        runRaw
                                                                        ( GeneratedChildRecoveryRevokeAccessor
                                                                            delivery
                                                                            revokePermit
                                                                            accessor
                                                                        )
                                                                    )
                                                                    ( \() ->
                                                                        controllerTerminal
                                                                          ( childWorkflowAfterRevoke
                                                                              workflow
                                                                              readBackState
                                                                          )
                                                                    )
                                                              )
                                                        )
                                                  )
                                            )
                                      )
                                )
                          )
                    )
              )
        )

validateGeneratedChildRecoverySession
  :: ChildRecoveryDelivery
  -> BootstrapVaultEffectPermit
  -> Either PgpBoundaryError GeneratedChildRecoverySessionEvidence
validateGeneratedChildRecoverySession delivery permit
  | observedEffect /= BootstrapVaultSubmitGenerateRootShare =
      Left
        ( PgpGeneratedChildRecoverySessionPermitMismatch
            BootstrapVaultSubmitGenerateRootShare
            observedEffect
        )
  | vaultEffectPermitStorageGeneration permit
      /= childCustodyStorageGeneration (childRecoveryDeliveryBinding delivery) =
      Left PgpGeneratedChildRecoverySessionGenerationMismatch
  | otherwise =
      Right (GeneratedChildRecoverySessionEvidence delivery permit)
 where
  observedEffect = vaultEffectPermitEffect permit

runCheckedGeneratedChildRecoveryAction
  :: (Applicative m)
  => GeneratedChildRecoverySessionEvidence
  -> ( forall actionResult
        . GeneratedChildRecoveryAction actionResult
       -> m (Either PgpBoundaryError actionResult)
     )
  -> GeneratedChildRecoveryAction result
  -> m (Either PgpBoundaryError result)
runCheckedGeneratedChildRecoveryAction evidence runRaw action =
  case validateGeneratedChildRecoveryAction evidence action of
    Left refusal -> pure (Left refusal)
    Right () -> runRaw action

validateGeneratedChildRecoveryAction
  :: GeneratedChildRecoverySessionEvidence
  -> GeneratedChildRecoveryAction actionResult
  -> Either PgpBoundaryError ()
validateGeneratedChildRecoveryAction
  ( GeneratedChildRecoverySessionEvidence
      expectedDelivery
      originatingPermit
    )
  action
    | delivery /= expectedDelivery =
        Left PgpGeneratedChildRecoveryActionBindingMismatch
    | observedEffect /= expectedEffect =
        Left
          ( PgpGeneratedChildRecoveryActionPermitMismatch
              expectedEffect
              observedEffect
          )
    | vaultEffectPermitStorageGeneration permit
        /= childCustodyStorageGeneration (childRecoveryDeliveryBinding delivery) =
        Left PgpGeneratedChildRecoveryActionGenerationMismatch
    | not (sameFenceIdentity originatingPermit permit) =
        Left PgpGeneratedChildRecoveryActionFenceIdentityMismatch
    | otherwise = Right ()
   where
    (delivery, permit, expectedEffect) = case action of
      GeneratedChildRecoveryObserveAccessor observedDelivery observedPermit ->
        ( observedDelivery
        , observedPermit
        , BootstrapVaultObserveGeneratedRootAccessor
        )
      GeneratedChildRecoveryApplyAllowlistedRepair observedDelivery observedPermit _ ->
        (observedDelivery, observedPermit, BootstrapVaultApplyBaseline)
      GeneratedChildRecoveryReadBackAllowlistedRepair observedDelivery observedPermit _ ->
        (observedDelivery, observedPermit, BootstrapVaultReadBackBaseline)
      GeneratedChildRecoveryRevokeAccessor observedDelivery observedPermit _ ->
        (observedDelivery, observedPermit, BootstrapVaultRevokeRootAccessor)
    observedEffect = vaultEffectPermitEffect permit

controllerStep
  :: (Monad m)
  => m (Either workflowError value)
  -> (value -> m (Either PgpBoundaryError (Either workflowError result)))
  -> m (Either PgpBoundaryError (Either workflowError result))
controllerStep action continue = do
  outcome <- action
  case outcome of
    Left refusal -> pure (Right (Left refusal))
    Right value -> continue value

pgpStep
  :: (Monad m)
  => m (Either PgpBoundaryError value)
  -> (value -> m (Either PgpBoundaryError (Either workflowError result)))
  -> m (Either PgpBoundaryError (Either workflowError result))
pgpStep action continue = do
  outcome <- action
  case outcome of
    Left refusal -> pure (Left refusal)
    Right value -> continue value

controllerTerminal
  :: (Functor m)
  => m (Either workflowError result)
  -> m (Either PgpBoundaryError (Either workflowError result))
controllerTerminal = fmap Right

-- | Equality of the durable fence identity deliberately excludes only the
-- per-call effect and its derived in-process deadline.  Every identity field
-- named by the durable fence is compared, preventing a token from being
-- relabelled onto a different request even when the storage generation agrees.
sameFenceIdentity
  :: BootstrapVaultEffectPermit -> BootstrapVaultEffectPermit -> Bool
sameFenceIdentity originatingPermit candidatePermit =
  vaultEffectPermitFenceGeneration candidatePermit
    == vaultEffectPermitFenceGeneration originatingPermit
    && vaultEffectPermitOwnerNonce candidatePermit
      == vaultEffectPermitOwnerNonce originatingPermit
    && vaultEffectPermitActionDigest candidatePermit
      == vaultEffectPermitActionDigest originatingPermit
    && vaultEffectPermitRequestDigest candidatePermit
      == vaultEffectPermitRequestDigest originatingPermit
    && vaultEffectPermitStorageGeneration candidatePermit
      == vaultEffectPermitStorageGeneration originatingPermit
    && vaultEffectPermitOperationDeadline candidatePermit
      == vaultEffectPermitOperationDeadline originatingPermit

-- | Trusted root-recipient interpreter seam.  Its constructor and eliminator
-- are private: interpreters can provide the bracket implementation through
-- 'mkGeneratedRootPrimitiveBoundary', but ordinary callers can only consume
-- the closed high-level workflow below.
--
-- The supplied session operation must decrypt the ciphertext into
-- interpreter-owned storage, keep the raw runner live only for the duration of
-- its callback, close and zeroize that storage on callback exit, and close it
-- immediately after a successful revoke.  Every raw action must check that
-- liveness state before touching Vault.  The callback result can never contain
-- plaintext through this type, and the private eliminator prevents a caller
-- from obtaining the raw runner through this module's public API.
newtype GeneratedRootPrimitiveBoundary m
  = GeneratedRootPrimitiveBoundary
      ( forall result
         . ( Text
             -> ( forall sessionResult
                   . ByteString
                  -> ( ( forall actionResult
                          . GeneratedRootAction actionResult
                         -> m (Either PgpBoundaryError actionResult)
                       )
                       -> m (Either PgpBoundaryError sessionResult)
                     )
                  -> m (Either PgpBoundaryError sessionResult)
                )
             -> m (Either PgpBoundaryError result)
           )
        -> m (Either PgpBoundaryError result)
      )

mkGeneratedRootPrimitiveBoundary
  :: ( forall result
        . ( Text
            -> ( forall sessionResult
                  . ByteString
                 -> ( ( forall actionResult
                         . GeneratedRootAction actionResult
                        -> m (Either PgpBoundaryError actionResult)
                      )
                      -> m (Either PgpBoundaryError sessionResult)
                    )
                 -> m (Either PgpBoundaryError sessionResult)
               )
            -> m (Either PgpBoundaryError result)
          )
       -> m (Either PgpBoundaryError result)
     )
  -> GeneratedRootPrimitiveBoundary m
mkGeneratedRootPrimitiveBoundary = GeneratedRootPrimitiveBoundary

-- | Child-recovery counterpart to 'GeneratedRootPrimitiveBoundary'.  The
-- same bracket, zeroization, immediate-revoke closure, and per-action liveness
-- obligations apply.
newtype GeneratedChildRecoveryPrimitiveBoundary m
  = GeneratedChildRecoveryPrimitiveBoundary
      ( forall result
         . ( Text
             -> ( forall sessionResult
                   . ByteString
                  -> ( ( forall actionResult
                          . GeneratedChildRecoveryAction actionResult
                         -> m (Either PgpBoundaryError actionResult)
                       )
                       -> m (Either PgpBoundaryError sessionResult)
                     )
                  -> m (Either PgpBoundaryError sessionResult)
                )
             -> m (Either PgpBoundaryError result)
           )
        -> m (Either PgpBoundaryError result)
      )

mkGeneratedChildRecoveryPrimitiveBoundary
  :: ( forall result
        . ( Text
            -> ( forall sessionResult
                  . ByteString
                 -> ( ( forall actionResult
                         . GeneratedChildRecoveryAction actionResult
                        -> m (Either PgpBoundaryError actionResult)
                      )
                      -> m (Either PgpBoundaryError sessionResult)
                    )
                 -> m (Either PgpBoundaryError sessionResult)
               )
            -> m (Either PgpBoundaryError result)
          )
       -> m (Either PgpBoundaryError result)
     )
  -> GeneratedChildRecoveryPrimitiveBoundary m
mkGeneratedChildRecoveryPrimitiveBoundary =
  GeneratedChildRecoveryPrimitiveBoundary

-- | Build the opaque root-recipient boundary from a trusted bracket.  The
-- fixed fold is the only callback given the raw runner, so callers can neither
-- inspect plaintext nor retain a runnable capability after revoke or return.
withGeneratedRootRecipientFromPrimitive
  :: (Monad m)
  => GeneratedRootPrimitiveBoundary m
  -> ( GeneratedRootPublicKey
       -> ( forall workflowError workflowState workflowResult
             . RootSessionBinding
            -> BootstrapVaultEffectPermit
            -> GeneratedRootCiphertext
            -> GeneratedRootWorkflow
                 m
                 workflowError
                 workflowState
                 workflowResult
            -> m
                 ( Either
                     PgpBoundaryError
                     (Either workflowError workflowResult)
                 )
          )
       -> m result
     )
  -> m (Either PgpBoundaryError result)
withGeneratedRootRecipientFromPrimitive primitive consume =
  case primitive of
    GeneratedRootPrimitiveBoundary withPrimitiveRecipient ->
      withPrimitiveRecipient $ \encodedPublicKey runScopedSession ->
        let decodedPublicKey = mkGeneratedRootPublicKey encodedPublicKey
         in case decodedPublicKey of
              Left refusal -> pure (Left refusal)
              Right publicKey ->
                Right
                  <$> consume
                    publicKey
                    ( \binding originatingPermit ciphertext workflow ->
                        let rootCiphertext = ciphertext
                         in case rootCiphertext of
                              GeneratedRootCiphertext ciphertextBytes ->
                                runScopedSession
                                  ciphertextBytes
                                  ( \runRaw ->
                                      runClosedGeneratedRootWorkflow
                                        binding
                                        originatingPermit
                                        runRaw
                                        workflow
                                  )
                    )

withGeneratedChildRecoveryRecipientFromPrimitive
  :: (Monad m)
  => GeneratedChildRecoveryPrimitiveBoundary m
  -> ( GeneratedChildRecoveryPublicKey
       -> ( forall workflowError workflowState workflowResult
             . ChildRecoveryDelivery
            -> BootstrapVaultEffectPermit
            -> GeneratedChildRecoveryCiphertext
            -> GeneratedChildRecoveryWorkflow
                 m
                 workflowError
                 workflowState
                 workflowResult
            -> m
                 ( Either
                     PgpBoundaryError
                     (Either workflowError workflowResult)
                 )
          )
       -> m result
     )
  -> m (Either PgpBoundaryError result)
withGeneratedChildRecoveryRecipientFromPrimitive primitive consume =
  case primitive of
    GeneratedChildRecoveryPrimitiveBoundary withPrimitiveRecipient ->
      withPrimitiveRecipient $ \encodedPublicKey runScopedSession ->
        let decodedPublicKey = mkGeneratedChildRecoveryPublicKey encodedPublicKey
         in case decodedPublicKey of
              Left refusal -> pure (Left refusal)
              Right publicKey ->
                Right
                  <$> consume
                    publicKey
                    ( \delivery originatingPermit ciphertext workflow ->
                        let childCiphertext = ciphertext
                         in case childCiphertext of
                              GeneratedChildRecoveryCiphertext ciphertextBytes ->
                                runScopedSession
                                  ciphertextBytes
                                  ( \runRaw ->
                                      runClosedGeneratedChildRecoveryWorkflow
                                        delivery
                                        originatingPermit
                                        runRaw
                                        workflow
                                  )
                    )

-- | Byte-level custody crypto implemented by the attested one-shot worker.
-- The smart constructor below is the only consumer: password bytes never
-- enter the high-level boundary and every primitive result is revalidated into
-- opaque evidence before it can reach Engine.
data PgpCustodyPrimitiveBoundary m = PgpCustodyPrimitiveBoundary
  { primitiveVerifyCompiledBurnRecipient
      :: Settings.CompiledBurnRecipient
      -> m
           ( Either
               PgpBoundaryError
               (Text, BurnRecipientFingerprint)
           )
  , primitivePrepareRecoveryRecipient
      :: ByteString
      -> PristineStorageProof
      -> BootstrapSchemaVersion
      -> VerifiedBurnRecipient
      -> Natural
      -> Natural
      -> ArtifactDigest
      -> m
           ( Either
               PgpBoundaryError
               (Text, RecoveryRecipientFingerprint, PreparedInitEnvelope)
           )
  , primitiveResumePreparedInitRecipients
      :: ByteString
      -> PreparedInitEnvelope
      -> VerifiedBurnRecipient
      -> m
           ( Either
               PgpBoundaryError
               (Text, RecoveryRecipientFingerprint)
           )
  , primitiveDecryptRecoveryShares
      :: ByteString
      -> PreparedInitRecipients
      -> EncryptedInitResponseReceipt
      -> m (Either PgpBoundaryError [ByteString])
  , primitiveSealFinalUnlockPayload
      :: ByteString
      -> FinalUnlockBundlePayload
      -> m (Either PgpBoundaryError ByteString)
  }

-- | Build the complete high-level PGP port from the three byte-level trusted
-- interpreter families.  'SecretPayload' and generated-root ciphertext are
-- unwrapped only in this module; all resulting credentials remain scoped.
mkPgpBoundary
  :: (Monad m)
  => PgpCustodyPrimitiveBoundary m
  -> GeneratedRootPrimitiveBoundary m
  -> GeneratedChildRecoveryPrimitiveBoundary m
  -> PgpBoundary m
mkPgpBoundary custodyPrimitive rootPrimitive childPrimitive =
  PgpBoundary
    { verifyCompiledBurnRecipient = \compiled -> do
        observed <- primitiveVerifyCompiledBurnRecipient custodyPrimitive compiled
        pure $ do
          (encodedPublicKey, observedFingerprint) <- observed
          publicKey <- mkBurnRecipientPublicKey encodedPublicKey
          mkVerifiedBurnRecipient compiled publicKey observedFingerprint
    , prepareRecoveryRecipient =
        \secret pristine schema burnRecipient shareCount threshold envelopeDigest ->
          RequestInternal.withSecretPayloadBytes secret $ \secretBytes -> do
            prepared <-
              primitivePrepareRecoveryRecipient
                custodyPrimitive
                secretBytes
                pristine
                schema
                burnRecipient
                shareCount
                threshold
                envelopeDigest
            pure $ do
              (encodedPublicKey, recoveryFingerprint, envelope) <- prepared
              validatePreparedInputs
                pristine
                schema
                shareCount
                threshold
                envelopeDigest
                envelope
              attestPreparedInitRecipients
                encodedPublicKey
                recoveryFingerprint
                envelope
                burnRecipient
    , resumePreparedInitRecipients = \secret envelope burnRecipient ->
        RequestInternal.withSecretPayloadBytes secret $ \secretBytes -> do
          resumed <-
            primitiveResumePreparedInitRecipients
              custodyPrimitive
              secretBytes
              envelope
              burnRecipient
          pure $ do
            (encodedPublicKey, recoveryFingerprint) <- resumed
            attestPreparedInitRecipients
              encodedPublicKey
              recoveryFingerprint
              envelope
              burnRecipient
    , decryptRecoveryShares = \secret recipients encryptedResponse ->
        RequestInternal.withSecretPayloadBytes secret $ \secretBytes -> do
          decrypted <-
            primitiveDecryptRecoveryShares
              custodyPrimitive
              secretBytes
              recipients
              encryptedResponse
          pure (decrypted >>= traverse recoveredShareFromBytes)
    , sealFinalUnlockPayload = \secret payload ->
        RequestInternal.withSecretPayloadBytes secret $ \secretBytes -> do
          sealed <-
            primitiveSealFinalUnlockPayload
              custodyPrimitive
              secretBytes
              payload
          pure (sealed >>= passwordCiphertextEvidenceFromBytes)
    , withGeneratedRootRecipient =
        withGeneratedRootRecipientFromPrimitive rootPrimitive
    , withGeneratedChildRecoveryRecipient =
        withGeneratedChildRecoveryRecipientFromPrimitive childPrimitive
    }

validatePreparedInputs
  :: PristineStorageProof
  -> BootstrapSchemaVersion
  -> Natural
  -> Natural
  -> ArtifactDigest
  -> PreparedInitEnvelope
  -> Either PgpBoundaryError ()
validatePreparedInputs pristine schema shareCount threshold envelopeDigest envelope
  | preparedInitBinding envelope /= pristineStorageBinding pristine =
      Left PgpPreparedRecoveryRecipientMismatch
  | preparedInitPristineObservationDigest envelope
      /= pristineStorageObservationDigest pristine =
      Left PgpPreparedRecoveryRecipientMismatch
  | preparedInitSchemaVersion envelope /= schema =
      Left PgpPreparedRecoveryRecipientMismatch
  | preparedInitRecipientShareCountFromEnvelope envelope /= shareCount =
      Left PgpPreparedRecoveryRecipientMismatch
  | preparedInitRecipientThresholdFromEnvelope envelope /= threshold =
      Left PgpPreparedRecoveryRecipientMismatch
  | preparedInitEnvelopeDigest envelope /= envelopeDigest =
      Left PgpPreparedRecoveryRecipientMismatch
  | otherwise = Right ()

attestPreparedInitRecipients
  :: Text
  -> RecoveryRecipientFingerprint
  -> PreparedInitEnvelope
  -> VerifiedBurnRecipient
  -> Either PgpBoundaryError PreparedInitRecipients
attestPreparedInitRecipients encodedPublicKey recoveryFingerprint envelope burnRecipient = do
  publicKey <- mkRecoveryRecipientPublicKey encodedPublicKey
  let commitment = preparedInitRecipientCommitment envelope
      recoveryPublicKeys = initRecipientRecoveryPublicKeysBase64 commitment
      expectedShareCount = initRecipientShareCount commitment
  if preparedInitRecoveryFingerprint envelope /= recoveryFingerprint
    || fromIntegral (length recoveryPublicKeys) /= expectedShareCount
    || any (/= encodedPublicKey) recoveryPublicKeys
    then Left PgpPreparedRecoveryRecipientMismatch
    else Right ()
  if initRecipientBurnFingerprint commitment
    /= verifiedBurnRecipientFingerprint burnRecipient
    || initRecipientBurnPublicKeyDigest commitment
      /= verifiedBurnRecipientPublicKeyDigest burnRecipient
    then Left PgpPreparedBurnRecipientMismatch
    else Right ()
  Right
    ( PreparedInitRecipients
        (PreparedRecoveryRecipient publicKey envelope)
        burnRecipient
    )

preparedInitRecipientShareCountFromEnvelope :: PreparedInitEnvelope -> Natural
preparedInitRecipientShareCountFromEnvelope =
  initRecipientShareCount . preparedInitRecipientCommitment

preparedInitRecipientThresholdFromEnvelope :: PreparedInitEnvelope -> Natural
preparedInitRecipientThresholdFromEnvelope =
  initRecipientThreshold . preparedInitRecipientCommitment

recoveredShareFromBytes
  :: ByteString -> Either PgpBoundaryError RecoveredUnsealShare
recoveredShareFromBytes =
  either (const (Left PgpEncryptedShareRejected)) Right . mkRecoveredUnsealShare

passwordCiphertextEvidenceFromBytes
  :: ByteString
  -> Either
       PgpBoundaryError
       (PasswordAeadCiphertext, ArtifactDigest)
passwordCiphertextEvidenceFromBytes bytes = do
  ciphertext <-
    either (const (Left PgpPasswordAeadFailed)) Right (mkPasswordAeadCiphertext bytes)
  digest <-
    either
      (const (Left PgpPasswordAeadFailed))
      Right
      (mkArtifactDigest (lowerHexBytes (SHA256.hash bytes)))
  Right (ciphertext, digest)

-- | Cryptographic port.  Passwords/private keys are scoped by the one-shot
-- worker interpreter.  Generated-token sessions expose only closed workflows:
-- the controller supplies durable transition hooks, while this boundary owns
-- the exact observe/apply/read-back/revoke order and never exports plaintext
-- or a runnable token capability.
data PgpBoundary m = PgpBoundary
  { verifyCompiledBurnRecipient
      :: Settings.CompiledBurnRecipient
      -> m (Either PgpBoundaryError VerifiedBurnRecipient)
  , prepareRecoveryRecipient
      :: SecretPayload
      -> PristineStorageProof
      -> BootstrapSchemaVersion
      -> VerifiedBurnRecipient
      -> Natural
      -> Natural
      -> ArtifactDigest
      -> m (Either PgpBoundaryError PreparedInitRecipients)
  , resumePreparedInitRecipients
      :: SecretPayload
      -> PreparedInitEnvelope
      -> VerifiedBurnRecipient
      -> m (Either PgpBoundaryError PreparedInitRecipients)
  , decryptRecoveryShares
      :: SecretPayload
      -> PreparedInitRecipients
      -> EncryptedInitResponseReceipt
      -> m (Either PgpBoundaryError [RecoveredUnsealShare])
  , sealFinalUnlockPayload
      :: SecretPayload
      -> FinalUnlockBundlePayload
      -> m
           ( Either
               PgpBoundaryError
               (PasswordAeadCiphertext, ArtifactDigest)
           )
  , withGeneratedRootRecipient
      :: forall result
       . ( GeneratedRootPublicKey
           -> ( forall workflowError workflowState workflowResult
                 . RootSessionBinding
                -> BootstrapVaultEffectPermit
                -> GeneratedRootCiphertext
                -> GeneratedRootWorkflow
                     m
                     workflowError
                     workflowState
                     workflowResult
                -> m
                     ( Either
                         PgpBoundaryError
                         (Either workflowError workflowResult)
                     )
              )
           -> m result
         )
      -> m (Either PgpBoundaryError result)
  , withGeneratedChildRecoveryRecipient
      :: forall result
       . ( GeneratedChildRecoveryPublicKey
           -> ( forall workflowError workflowState workflowResult
                 . ChildRecoveryDelivery
                -> BootstrapVaultEffectPermit
                -> GeneratedChildRecoveryCiphertext
                -> GeneratedChildRecoveryWorkflow
                     m
                     workflowError
                     workflowState
                     workflowResult
                -> m
                     ( Either
                         PgpBoundaryError
                         (Either workflowError workflowResult)
                     )
              )
           -> m result
         )
      -> m (Either PgpBoundaryError result)
  }

validatePublicKeyBase64 :: Text -> Either PgpBoundaryError Text
validatePublicKeyBase64 encoded
  | Text.null encoded || encoded /= Text.strip encoded || Text.length encoded > 65536 =
      Left PgpRecipientGenerationFailed
  | otherwise =
      case Base64.decode encodedBytes of
        Left _ -> Left PgpRecipientPublicKeyNotCanonicalBase64
        Right decoded
          | BS.null decoded || Base64.encode decoded /= encodedBytes ->
              Left PgpRecipientPublicKeyNotCanonicalBase64
          | otherwise -> Right encoded
 where
  encodedBytes = TextEncoding.encodeUtf8 encoded

digestPublicKey :: Text -> Either PgpBoundaryError ArtifactDigest
digestPublicKey encoded =
  case Base64.decode (TextEncoding.encodeUtf8 encoded) of
    Left _ -> Left PgpRecipientPublicKeyNotCanonicalBase64
    Right decoded ->
      case mkArtifactDigest (lowerHexBytes (SHA256.hash decoded)) of
        Left _ -> Left PgpRecipientGenerationFailed
        Right digest -> Right digest

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap renderHexByte . BS.unpack
 where
  renderHexByte byte =
    case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits
