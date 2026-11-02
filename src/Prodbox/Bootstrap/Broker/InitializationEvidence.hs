{-# LANGUAGE OverloadedStrings #-}

-- | Fresh initialization and continuation of a retained journal are different
-- admissions. A continuation never licenses creating a missing journal.
module Prodbox.Bootstrap.Broker.InitializationEvidence
  ( PristineJournalRefusal (..)
  , classifyPristineJournalAgainst
  , RootInitJournalObservation (..)
  , RootInitializationEvidence (..)
  , RootInitResumeEvidence
  , rootInitResumePristineCommitment
  , rootInitResumeSnapshot
  , rootInitResumeVersion
  , classifyRootInitializationEvidence
  , RootInitJournalPhase (..)
  , rootInitJournalPhase
  , rootInitResetFromGeneration
  , rootInitResetActionDigest
  , rootInitJournalPhaseText
  , parseRootInitJournalPhase
  , rootInitializationPending
  , RootInitEvidenceStage (..)
  , RootInitializationEvidenceCause (..)
  , rootInitEvidenceUnavailable
  , rootInitEvidenceCauseCode
  ) where

import Data.List (find)
import Data.Text (Text)
import Prodbox.Bootstrap.Broker.Custody
import Prodbox.Bootstrap.Broker.Types

data RootInitJournalObservation
  = RootInitJournalAbsent
  | RootInitJournalPresent !StoreVersion !RootInitState
  deriving (Eq, Show)

data PristineJournalRefusal
  = PristineJournalBindingMismatch
  | PristineJournalProofMismatch
  | PristineJournalPhaseAdvanced
  deriving (Eq, Show)

classifyPristineJournalAgainst
  :: PristineStorageProof
  -> RootInitJournalObservation
  -> Either PristineJournalRefusal PristineStorageProof
classifyPristineJournalAgainst expected observation = case observation of
  RootInitJournalAbsent -> Right expected
  RootInitJournalPresent _ state
    | rootInitStateBinding state /= pristineStorageBinding expected ->
        Left PristineJournalBindingMismatch
    | otherwise -> case rootInitStatePhase state of
        RootInitPristine proof
          | proof == expected -> Right proof
          | otherwise -> Left PristineJournalProofMismatch
        RootResetPristine reset
          | resetReplacementPristine reset == expected -> Right expected
          | otherwise -> Left PristineJournalProofMismatch
        _ -> Left PristineJournalPhaseAdvanced

data RootInitializationEvidence
  = BeginRootInitialization !PristineStorageProof
  | ContinueRootInitialization !RootInitResumeEvidence
  deriving (Eq, Show)

-- The commitment describes the originally admitted pristine generation. It
-- does not assert that this advanced journal is currently pristine.
data RootInitResumeEvidence
  = RootInitResumeEvidence
      !PristineStorageProof
      !StoreVersion
      !RootInitState
  deriving (Eq, Show)

rootInitResumePristineCommitment :: RootInitResumeEvidence -> PristineStorageProof
rootInitResumePristineCommitment (RootInitResumeEvidence proof _ _) = proof

rootInitResumeVersion :: RootInitResumeEvidence -> StoreVersion
rootInitResumeVersion (RootInitResumeEvidence _ version _) = version

rootInitResumeSnapshot :: RootInitResumeEvidence -> RootInitState
rootInitResumeSnapshot (RootInitResumeEvidence _ _ state) = state

data RootInitJournalPhase
  = InitPristine
  | InitResetPristine
  | InitPreparedWritePending
  | InitPreparedWritten
  | InitPreparedReadBack
  | InitCallPending
  | InitCallInFlight
  | InitResponseCapturePending
  | InitResponseWritten
  | InitResponseReadBack
  | InitFinalPromotionPending
  | InitFinalPromoted
  | InitFinalReadBack
  | InitPreparedDeletionPending
  | InitPreparedDeleted
  | InitPreparedAbsent
  | InitCustodyAcknowledgementPending
  | InitCustodyDurable
  | InitAmbiguous
  | InitResetInFlight
  deriving (Eq, Ord, Show, Enum, Bounded)

rootInitJournalPhase :: RootInitPhase -> RootInitJournalPhase
rootInitJournalPhase phase = case phase of
  RootInitPristine {} -> InitPristine
  RootResetPristine {} -> InitResetPristine
  RootPreparedWritePending {} -> InitPreparedWritePending
  RootPreparedWritten {} -> InitPreparedWritten
  RootPreparedReadBack {} -> InitPreparedReadBack
  RootInitCallPending {} -> InitCallPending
  RootInitCallInFlight {} -> InitCallInFlight
  RootEncryptedResponseCapturePending {} -> InitResponseCapturePending
  RootEncryptedResponseWritten {} -> InitResponseWritten
  RootEncryptedResponseReadBack {} -> InitResponseReadBack
  RootFinalBundlePromotionPending {} -> InitFinalPromotionPending
  RootFinalBundlePromoted {} -> InitFinalPromoted
  RootFinalBundleReadBack {} -> InitFinalReadBack
  RootPreparedDeletionPending {} -> InitPreparedDeletionPending
  RootPreparedDeleted {} -> InitPreparedDeleted
  RootPreparedAbsent {} -> InitPreparedAbsent
  RootRecoveryCustodyAcknowledgementPending {} -> InitCustodyAcknowledgementPending
  RootRecoveryCustodyDurable {} -> InitCustodyDurable
  RootInitializationAmbiguous {} -> InitAmbiguous
  RootResetInFlight {} -> InitResetInFlight

rootInitResetFromGeneration :: RootInitPhase -> Maybe VaultStorageGeneration
rootInitResetFromGeneration phase = case phase of
  RootResetPristine proof -> Just (rootInitStorageGeneration (resetAmbiguousBinding proof))
  RootResetInFlight proof _ -> Just (rootInitStorageGeneration (resetAmbiguousBinding proof))
  _ -> Nothing

rootInitResetActionDigest :: RootInitPhase -> Maybe ArtifactDigest
rootInitResetActionDigest phase = case phase of
  RootResetInFlight _ action -> Just action
  _ -> Nothing

rootInitJournalPhaseText :: RootInitJournalPhase -> Text
rootInitJournalPhaseText phase = case phase of
  InitPristine -> "pristine"
  InitResetPristine -> "reset-pristine"
  InitPreparedWritePending -> "prepared-write-pending"
  InitPreparedWritten -> "prepared-written"
  InitPreparedReadBack -> "prepared-read-back"
  InitCallPending -> "init-call-pending"
  InitCallInFlight -> "init-call-in-flight"
  InitResponseCapturePending -> "response-capture-pending"
  InitResponseWritten -> "response-written"
  InitResponseReadBack -> "response-read-back"
  InitFinalPromotionPending -> "final-promotion-pending"
  InitFinalPromoted -> "final-promoted"
  InitFinalReadBack -> "final-read-back"
  InitPreparedDeletionPending -> "prepared-deletion-pending"
  InitPreparedDeleted -> "prepared-deleted"
  InitPreparedAbsent -> "prepared-absent"
  InitCustodyAcknowledgementPending -> "custody-acknowledgement-pending"
  InitCustodyDurable -> "custody-durable"
  InitAmbiguous -> "ambiguous"
  InitResetInFlight -> "reset-in-flight"

parseRootInitJournalPhase :: Text -> Maybe RootInitJournalPhase
parseRootInitJournalPhase value = find ((== value) . rootInitJournalPhaseText) [minBound .. maxBound]

rootInitializationPending :: RootInitJournalPhase -> Bool
rootInitializationPending phase = case phase of
  InitPristine -> False
  InitResetPristine -> False
  InitPreparedWritePending -> True
  InitPreparedWritten -> True
  InitPreparedReadBack -> True
  InitCallPending -> True
  InitCallInFlight -> True
  InitResponseCapturePending -> True
  InitResponseWritten -> True
  InitResponseReadBack -> True
  InitFinalPromotionPending -> True
  InitFinalPromoted -> True
  InitFinalReadBack -> True
  InitPreparedDeletionPending -> True
  InitPreparedDeleted -> True
  InitPreparedAbsent -> True
  InitCustodyAcknowledgementPending -> True
  InitCustodyDurable -> False
  InitAmbiguous -> False
  InitResetInFlight -> True

data RootInitEvidenceStage = InitGenerationRead | InitStatusRead | InitJournalRead | InitResumeRead
  deriving (Eq, Show)

data RootInitializationEvidenceCause
  = InitEvidenceUnavailable !RootInitEvidenceStage
  | InitEvidenceCorrupt !RootInitEvidenceStage
  | InitEvidenceBindingMismatch !RootInitEvidenceStage
  | InitEvidenceVersionConflict !RootInitEvidenceStage
  | InitEvidenceReadBackMismatch !RootInitEvidenceStage
  | InitEvidenceRequestGenerationMismatch
  | InitEvidencePristineRefused !PristineJournalRefusal
  | InitEvidenceJournalInvalid
  | InitEvidenceOriginalPristineMismatch !RootInitJournalPhase
  | InitEvidenceCancelled
  | InitEvidenceAmbiguousNeedsReset
  | InitEvidenceVaultStateMismatch !RootInitJournalPhase
  | InitEvidenceResumeAbsent
  | InitEvidenceResumeChanged
  deriving (Eq, Show)

rootInitEvidenceUnavailable :: RootInitializationEvidenceCause -> Bool
rootInitEvidenceUnavailable cause = case cause of
  InitEvidenceUnavailable _ -> True
  InitEvidenceCorrupt _ -> False
  InitEvidenceBindingMismatch _ -> False
  InitEvidenceVersionConflict _ -> False
  InitEvidenceReadBackMismatch _ -> False
  InitEvidenceRequestGenerationMismatch -> False
  InitEvidencePristineRefused _ -> False
  InitEvidenceJournalInvalid -> False
  InitEvidenceOriginalPristineMismatch _ -> False
  InitEvidenceCancelled -> False
  InitEvidenceAmbiguousNeedsReset -> False
  InitEvidenceVaultStateMismatch _ -> False
  InitEvidenceResumeAbsent -> False
  InitEvidenceResumeChanged -> False

rootInitEvidenceCauseCode :: RootInitializationEvidenceCause -> String
rootInitEvidenceCauseCode = show

classifyRootInitializationEvidence
  :: PristineStorageProof
  -> Bool
  -> RootInitJournalObservation
  -> Either RootInitializationEvidenceCause RootInitializationEvidence
classifyRootInitializationEvidence expected initialized observation = do
  case observation of
    RootInitJournalAbsent -> fresh InitPristine
    RootInitJournalPresent version state
      | pendingResetMatches expected state -> Left InitEvidenceAmbiguousNeedsReset
      | rootInitStateBinding state /= pristineStorageBinding expected ->
          Left (InitEvidencePristineRefused PristineJournalBindingMismatch)
      | not (null (rootInitInvariantViolations state)) -> Left InitEvidenceJournalInvalid
      | not (originalCommitmentMatches expected (rootInitStatePhase state)) ->
          Left (InitEvidenceOriginalPristineMismatch (rootInitJournalPhase (rootInitStatePhase state)))
      | otherwise -> case rootInitStateDisposition state of
          CustodyCancellationRequested _ -> Left InitEvidenceCancelled
          CustodyRunning ->
            let phase = rootInitJournalPhase (rootInitStatePhase state)
                resume = Right (ContinueRootInitialization (RootInitResumeEvidence expected version state))
             in case phase of
                  InitPristine -> fresh phase
                  InitResetPristine -> fresh phase
                  InitPreparedWritePending -> beforeCall phase resume
                  InitPreparedWritten -> beforeCall phase resume
                  InitPreparedReadBack -> beforeCall phase resume
                  InitCallPending -> beforeCall phase resume
                  InitCallInFlight -> resume
                  InitResponseCapturePending -> afterCall phase resume
                  InitResponseWritten -> afterCall phase resume
                  InitResponseReadBack -> afterCall phase resume
                  InitFinalPromotionPending -> afterCall phase resume
                  InitFinalPromoted -> afterCall phase resume
                  InitFinalReadBack -> afterCall phase resume
                  InitPreparedDeletionPending -> afterCall phase resume
                  InitPreparedDeleted -> afterCall phase resume
                  InitPreparedAbsent -> afterCall phase resume
                  InitCustodyAcknowledgementPending -> afterCall phase resume
                  InitCustodyDurable -> afterCall phase resume
                  InitAmbiguous -> Left InitEvidenceAmbiguousNeedsReset
                  InitResetInFlight -> Left InitEvidenceAmbiguousNeedsReset
 where
  fresh phase
    | initialized = Left (InitEvidenceVaultStateMismatch phase)
    | otherwise =
        either
          (Left . InitEvidencePristineRefused)
          (Right . BeginRootInitialization)
          (classifyPristineJournalAgainst expected observation)
  beforeCall phase result
    | initialized = Left (InitEvidenceVaultStateMismatch phase)
    | otherwise = result
  afterCall phase result
    | initialized = result
    | otherwise = Left (InitEvidenceVaultStateMismatch phase)

pendingResetMatches :: PristineStorageProof -> RootInitState -> Bool
pendingResetMatches expected state = case rootInitStatePhase state of
  RootResetInFlight proof _ ->
    null (rootInitInvariantViolations state)
      && ( pristineStorageBinding expected == resetAmbiguousBinding proof
             || pristineStorageBinding expected == pristineStorageBinding (resetReplacementPristine proof)
         )
  _ -> False

originalCommitmentMatches :: PristineStorageProof -> RootInitPhase -> Bool
originalCommitmentMatches proof phase = case phase of
  RootInitPristine {} -> True
  RootResetPristine {} -> True
  RootPreparedWritePending prepared -> matches prepared
  RootPreparedWritten prepared -> matches prepared
  RootPreparedReadBack prepared -> matches prepared
  RootInitCallPending prepared -> matches prepared
  RootInitCallInFlight prepared -> matches prepared
  RootEncryptedResponseCapturePending prepared _ -> matches prepared
  RootEncryptedResponseWritten prepared _ -> matches prepared
  RootEncryptedResponseReadBack prepared _ -> matches prepared
  RootFinalBundlePromotionPending prepared _ _ -> matches prepared
  RootFinalBundlePromoted prepared _ _ -> matches prepared
  RootFinalBundleReadBack prepared _ _ -> matches prepared
  RootPreparedDeletionPending prepared _ -> matches prepared
  RootPreparedDeleted prepared _ -> matches prepared
  RootPreparedAbsent {} -> True
  RootRecoveryCustodyAcknowledgementPending {} -> True
  RootRecoveryCustodyDurable {} -> True
  RootInitializationAmbiguous {} -> True
  RootResetInFlight {} -> True
 where
  matches prepared = preparedInitPristineObservationDigest prepared == pristineStorageObservationDigest proof
