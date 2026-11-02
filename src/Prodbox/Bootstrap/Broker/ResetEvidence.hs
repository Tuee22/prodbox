{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure admission for one audited reset operation. A pending proof survives
-- preparation retirement and is never reconstructed from current absence.
module Prodbox.Bootstrap.Broker.ResetEvidence
  ( RootResetAdmission (..)
  , RootResetEvidenceStage (..)
  , RootResetEvidenceCause (..)
  , classifyRootResetEvidence
  , rootResetEvidenceUnavailable
  , rootResetRequestGeneration
  , RootResetClientBinding (..)
  , rootResetClientBinding
  , deriveRootResetBinding
  , rootResetIdentityMatches
  ) where

import Codec.Serialise (serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.Bootstrap.Broker.Custody
import Prodbox.Bootstrap.Broker.InitializationEvidence (RootInitJournalPhase (InitResetInFlight))
import Prodbox.Bootstrap.Broker.Types

data RootResetAdmission
  = AuditAmbiguousRootReset !InitAmbiguity
  | ResumeAuditedRootReset !PristineResetProof
  deriving (Eq, Show)

data RootResetEvidenceStage
  = ResetGenerationRead
  | ResetJournalRead
  | ResetPreparedRead
  | ResetResponseRead
  | ResetFinalBundleRead
  | ResetSessionRead
  | ResetHandoffRead
  | ResetVaultSealRead
  | ResetStorageIdentityRead
  deriving (Eq, Show)

data RootResetEvidenceCause
  = ResetEvidenceUnavailable !RootResetEvidenceStage
  | ResetEvidenceCorrupt !RootResetEvidenceStage
  | ResetEvidenceBindingMismatch !RootResetEvidenceStage
  | ResetEvidenceVersionConflict !RootResetEvidenceStage
  | ResetEvidenceReadBackMismatch !RootResetEvidenceStage
  | ResetEvidenceJournalAbsent
  | ResetEvidenceJournalInvalid
  | ResetEvidenceCancelledBeforeArm
  | ResetEvidenceRequestedGenerationMismatch
  | ResetEvidenceUnjournaledGenerationAdvance
  | ResetEvidenceCurrentBindingMismatch
  | ResetEvidencePendingActionMismatch
  | ResetEvidenceNotAmbiguous
  | ResetEvidenceEstablishedGeneration
  | ResetEvidencePreparedAbsent
  | ResetEvidencePreparedMismatch
  | ResetEvidenceExpectedAbsent !RootResetEvidenceStage
  | ResetEvidenceAuditProofInvalid
  | ResetEvidencePendingGenerationAbsent
  | ResetEvidencePendingActionAbsent
  deriving (Eq, Show)

rootResetEvidenceUnavailable :: RootResetEvidenceCause -> Bool
rootResetEvidenceUnavailable cause = case cause of
  ResetEvidenceUnavailable _ -> True
  ResetEvidenceCorrupt _ -> False
  ResetEvidenceBindingMismatch _ -> False
  ResetEvidenceVersionConflict _ -> False
  ResetEvidenceReadBackMismatch _ -> False
  ResetEvidenceJournalAbsent -> False
  ResetEvidenceJournalInvalid -> False
  ResetEvidenceCancelledBeforeArm -> False
  ResetEvidenceRequestedGenerationMismatch -> False
  ResetEvidenceUnjournaledGenerationAdvance -> False
  ResetEvidenceCurrentBindingMismatch -> False
  ResetEvidencePendingActionMismatch -> False
  ResetEvidenceNotAmbiguous -> False
  ResetEvidenceEstablishedGeneration -> False
  ResetEvidencePreparedAbsent -> False
  ResetEvidencePreparedMismatch -> False
  ResetEvidenceExpectedAbsent _ -> False
  ResetEvidenceAuditProofInvalid -> False
  ResetEvidencePendingGenerationAbsent -> False
  ResetEvidencePendingActionAbsent -> False

classifyRootResetEvidence
  :: VaultStorageGeneration
  -> ArtifactDigest
  -> RootInitBinding
  -> Maybe RootInitState
  -> Either RootResetEvidenceCause RootResetAdmission
classifyRootResetEvidence requested action current journal = case journal of
  Nothing -> Left ResetEvidenceJournalAbsent
  Just state
    | not (null (rootInitInvariantViolations state)) -> Left ResetEvidenceJournalInvalid
    | otherwise -> case rootInitStatePhase state of
        RootInitializationAmbiguous ambiguity
          | rootInitStorageGeneration (ambiguousInitBinding ambiguity) /= requested ->
              Left ResetEvidenceRequestedGenerationMismatch
          | rootInitStateDisposition state /= CustodyRunning ->
              Left ResetEvidenceCancelledBeforeArm
          | current /= ambiguousInitBinding ambiguity ->
              Left ResetEvidenceUnjournaledGenerationAdvance
          | otherwise -> Right (AuditAmbiguousRootReset ambiguity)
        RootResetInFlight proof recordedAction
          | action /= recordedAction -> Left ResetEvidencePendingActionMismatch
          | otherwise -> persisted proof
        RootResetPristine proof -> persisted proof
        RootRecoveryCustodyDurable {} -> Left ResetEvidenceEstablishedGeneration
        _ -> Left ResetEvidenceNotAmbiguous
 where
  persisted proof
    | rootInitStorageGeneration (resetAmbiguousBinding proof) /= requested =
        Left ResetEvidenceRequestedGenerationMismatch
    | current /= resetAmbiguousBinding proof
        && current /= pristineStorageBinding (resetReplacementPristine proof) =
        Left ResetEvidenceCurrentBindingMismatch
    | otherwise = Right (ResumeAuditedRootReset proof)

-- A fresh client learns this binding from the durable pending proof. It never
-- guesses that the current generation is still the operation's old generation.
rootResetRequestGeneration
  :: VaultStorageGeneration
  -> Maybe RootInitJournalPhase
  -> Maybe VaultStorageGeneration
  -> Either RootResetEvidenceCause VaultStorageGeneration
rootResetRequestGeneration current phase predecessor = case phase of
  Just InitResetInFlight -> maybe (Left ResetEvidencePendingGenerationAbsent) Right predecessor
  _ -> Right current

data RootResetClientBinding
  = BeginRootResetRequest !VaultStorageGeneration
  | ResumeRootResetRequest !VaultStorageGeneration !ArtifactDigest
  deriving (Eq, Show)

rootResetClientBinding
  :: VaultStorageGeneration
  -> Maybe RootInitJournalPhase
  -> Maybe VaultStorageGeneration
  -> Maybe ArtifactDigest
  -> Either RootResetEvidenceCause RootResetClientBinding
rootResetClientBinding current phase predecessor action = case phase of
  Just InitResetInFlight -> do
    requested <- rootResetRequestGeneration current phase predecessor
    recorded <- maybe (Left ResetEvidencePendingActionAbsent) Right action
    Right (ResumeRootResetRequest requested recorded)
  _ -> Right (BeginRootResetRequest current)

-- This is the existing production derivation. The physical boundary repeats it
-- against its current PVC observation before a destructive effect.
deriveRootResetBinding
  :: ArtifactDigest -> InitAmbiguity -> Text -> Either RootResetEvidenceCause RootInitBinding
deriveRootResetBinding action ambiguity identity = do
  let suffix = Text.pack (concatMap hexByte (ByteString.unpack commitment))
      commitment =
        SHA256.hash
          ( LazyByteString.toStrict
              (serialise ("bootstrap-vault-storage-reset-v1" :: Text, ambiguity, action, identity))
          )
  transaction <-
    either
      (const (Left ResetEvidenceAuditProofInvalid))
      Right
      (mkBootstrapTransactionId ("reset-" <> suffix))
  generation <-
    either
      (const (Left ResetEvidenceAuditProofInvalid))
      Right
      (mkVaultStorageGeneration ("vault-reset-" <> suffix))
  Right (RootInitBinding transaction generation)
 where
  hexByte byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

rootResetIdentityMatches :: ArtifactDigest -> PristineResetProof -> Text -> Bool
rootResetIdentityMatches action proof identity =
  deriveRootResetBinding action (resetAmbiguity proof) identity
    == Right (pristineStorageBinding (resetReplacementPristine proof))
