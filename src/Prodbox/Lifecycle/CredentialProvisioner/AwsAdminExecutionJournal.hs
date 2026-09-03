{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Durable, secret-free create/recovery journal for one AWS-admin permit.
-- Every possibly-applied access-key create has a committed attempt (including
-- the exact predecessor inventory) before the AWS effect.  A response loss or
-- restart can therefore classify inventory, converge through delete plus
-- provider-grace stable absence, and authorize at most one remint.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionJournal
  ( AwsAdminExecutionJournal
  , AwsAdminExecutionPhase (..)
  , AwsAdminExecutionEvent (..)
  , AwsAdminExecutionJournalError (..)
  , initialAwsAdminExecutionJournal
  , awsAdminExecutionJournalPermit
  , awsAdminExecutionJournalPhase
  , stepAwsAdminExecutionJournal
  , encodeAwsAdminExecutionJournal
  , decodeAwsAdminExecutionJournal
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , decodeTargetWorkerReceipt
  , encodeTargetWorkerReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminPermitIntentCleanupPredecessor
  , decodeSignedAwsAdminPermit
  , encodeSignedAwsAdminPermit
  , signedAwsAdminPermitIntent
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( ProvisionedAccessKeyId
  , mkProvisionedAccessKeyId
  , provisionedAccessKeyIdText
  )

data AwsAdminExecutionPhase
  = AwsAdminExecutionIntentCommitted !Bool
  | AwsAdminExecutionCreateAttemptPrepared
      ![ProvisionedAccessKeyId]
      !Bool
  | AwsAdminExecutionKeyCreated
      !ProvisionedAccessKeyId
      ![ProvisionedAccessKeyId]
      !Bool
  | AwsAdminExecutionTargetCommitted
      !ProvisionedAccessKeyId
      ![ProvisionedAccessKeyId]
      !TargetWorkerReceipt
      !Bool
  | AwsAdminExecutionCleanupRequired !Bool
  | AwsAdminExecutionCleanupProven !Bool
  | AwsAdminExecutionComplete !ByteString
  deriving stock (Eq, Show)

data AwsAdminExecutionJournal = AwsAdminExecutionJournal
  { internalAwsAdminExecutionJournalPermit :: !SignedAwsAdminPermit
  , internalAwsAdminExecutionJournalPhase :: !AwsAdminExecutionPhase
  }
  deriving stock (Eq, Show)

data AwsAdminExecutionEvent
  = CommitAwsAdminCreateAttempt ![ProvisionedAccessKeyId] !Bool
  | CommitAwsAdminCreatedKey
      !ProvisionedAccessKeyId
      ![ProvisionedAccessKeyId]
      !Bool
  | CommitAwsAdminTargetReceipt
      !ProvisionedAccessKeyId
      ![ProvisionedAccessKeyId]
      !TargetWorkerReceipt
      !Bool
  | RequireAwsAdminStableCleanup !Bool
  | CommitAwsAdminStableCleanup !Bool
  | RestartAwsAdminAfterCleanup
  | CompleteAwsAdminExecution !ByteString
  deriving stock (Eq, Show)

data AwsAdminExecutionJournalError
  = AwsAdminExecutionTransitionRefused
  | AwsAdminExecutionTransitionConflict
  | AwsAdminExecutionJournalTooLarge !Int !Int
  | AwsAdminExecutionJournalDecodeFailed
  | AwsAdminExecutionJournalUnsupportedVersion !Word16
  | AwsAdminExecutionJournalInvalid
  | AwsAdminExecutionJournalNonCanonical
  deriving stock (Eq, Show)

initialAwsAdminExecutionJournal
  :: SignedAwsAdminPermit -> AwsAdminExecutionJournal
initialAwsAdminExecutionJournal permit =
  AwsAdminExecutionJournal permit initialPhase
 where
  initialPhase =
    case awsAdminPermitIntentCleanupPredecessor (signedAwsAdminPermitIntent permit) of
      Just _ -> AwsAdminExecutionCleanupRequired False
      Nothing -> AwsAdminExecutionIntentCommitted False

awsAdminExecutionJournalPermit
  :: AwsAdminExecutionJournal -> SignedAwsAdminPermit
awsAdminExecutionJournalPermit = internalAwsAdminExecutionJournalPermit

awsAdminExecutionJournalPhase
  :: AwsAdminExecutionJournal -> AwsAdminExecutionPhase
awsAdminExecutionJournalPhase = internalAwsAdminExecutionJournalPhase

stepAwsAdminExecutionJournal
  :: AwsAdminExecutionEvent
  -> AwsAdminExecutionJournal
  -> Either AwsAdminExecutionJournalError AwsAdminExecutionJournal
stepAwsAdminExecutionJournal event journal = do
  nextPhase <- stepPhase event (awsAdminExecutionJournalPhase journal)
  pure journal {internalAwsAdminExecutionJournalPhase = nextPhase}

stepPhase
  :: AwsAdminExecutionEvent
  -> AwsAdminExecutionPhase
  -> Either AwsAdminExecutionJournalError AwsAdminExecutionPhase
stepPhase event phase = case (phase, event) of
  (AwsAdminExecutionIntentCommitted used, CommitAwsAdminCreateAttempt predecessors actualUsed)
    | used == actualUsed ->
        Right (AwsAdminExecutionCreateAttemptPrepared predecessors used)
    | otherwise -> Left AwsAdminExecutionTransitionConflict
  (AwsAdminExecutionCleanupProven False, RestartAwsAdminAfterCleanup) ->
    Right (AwsAdminExecutionIntentCommitted True)
  ( AwsAdminExecutionCreateAttemptPrepared expected used
    , CommitAwsAdminCreatedKey key predecessors actualUsed
    )
      | expected == predecessors && used == actualUsed ->
          Right (AwsAdminExecutionKeyCreated key predecessors used)
      | otherwise -> Left AwsAdminExecutionTransitionConflict
  ( AwsAdminExecutionKeyCreated key predecessors used
    , CommitAwsAdminTargetReceipt actualKey actualPredecessors receipt actualUsed
    )
      | key == actualKey && predecessors == actualPredecessors && used == actualUsed ->
          Right (AwsAdminExecutionTargetCommitted key predecessors receipt used)
      | otherwise -> Left AwsAdminExecutionTransitionConflict
  (AwsAdminExecutionCreateAttemptPrepared _ used, RequireAwsAdminStableCleanup actualUsed)
    | used == actualUsed -> Right (AwsAdminExecutionCleanupRequired used)
    | otherwise -> Left AwsAdminExecutionTransitionConflict
  (AwsAdminExecutionKeyCreated _ _ used, RequireAwsAdminStableCleanup actualUsed)
    | used == actualUsed -> Right (AwsAdminExecutionCleanupRequired used)
    | otherwise -> Left AwsAdminExecutionTransitionConflict
  (AwsAdminExecutionCleanupRequired used, CommitAwsAdminStableCleanup actualUsed)
    | used == actualUsed -> Right (AwsAdminExecutionCleanupProven used)
    | otherwise -> Left AwsAdminExecutionTransitionConflict
  (AwsAdminExecutionTargetCommitted {}, CompleteAwsAdminExecution receipt) ->
    Right (AwsAdminExecutionComplete receipt)
  (AwsAdminExecutionIntentCommitted _, CompleteAwsAdminExecution receipt) ->
    Right (AwsAdminExecutionComplete receipt)
  (_, _)
    | eventMatchesPhase event phase -> Right phase
    | otherwise -> Left AwsAdminExecutionTransitionRefused

eventMatchesPhase :: AwsAdminExecutionEvent -> AwsAdminExecutionPhase -> Bool
eventMatchesPhase event phase = case (event, phase) of
  ( CommitAwsAdminCreateAttempt predecessors used
    , AwsAdminExecutionCreateAttemptPrepared actualPredecessors actualUsed
    ) ->
      predecessors == actualPredecessors && used == actualUsed
  ( CommitAwsAdminCreatedKey key predecessors used
    , AwsAdminExecutionKeyCreated actualKey actualPredecessors actualUsed
    ) ->
      key == actualKey && predecessors == actualPredecessors && used == actualUsed
  ( CommitAwsAdminTargetReceipt key predecessors receipt used
    , AwsAdminExecutionTargetCommitted actualKey actualPredecessors actualReceipt actualUsed
    ) ->
      key == actualKey
        && predecessors == actualPredecessors
        && receipt == actualReceipt
        && used == actualUsed
  (RequireAwsAdminStableCleanup used, AwsAdminExecutionCleanupRequired actualUsed) ->
    used == actualUsed
  (CommitAwsAdminStableCleanup used, AwsAdminExecutionCleanupProven actualUsed) ->
    used == actualUsed
  (CompleteAwsAdminExecution receipt, AwsAdminExecutionComplete actual) -> receipt == actual
  _ -> False

data WireExecutionPhase = WireExecutionPhase
  { wirePhaseTag :: !Word8
  , wirePhaseKeyId :: !(Maybe Text)
  , wirePhasePredecessorKeyIds :: ![Text]
  , wirePhaseRecoveryUsed :: !Bool
  , wirePhaseTargetReceipt :: !(Maybe ByteString)
  , wirePhaseWorkerReceipt :: !(Maybe ByteString)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireExecutionJournal = WireExecutionJournal
  { wireJournalVersion :: !Word16
  , wireJournalPermit :: !ByteString
  , wireJournalPhase :: !WireExecutionPhase
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

executionJournalVersion :: Word16
executionJournalVersion = 1

executionJournalMaximumBytes :: Int
executionJournalMaximumBytes = 96 * 1024

encodeAwsAdminExecutionJournal :: AwsAdminExecutionJournal -> ByteString
encodeAwsAdminExecutionJournal = LazyByteString.toStrict . serialise . journalToWire

decodeAwsAdminExecutionJournal
  :: ByteString -> Either AwsAdminExecutionJournalError AwsAdminExecutionJournal
decodeAwsAdminExecutionJournal bytes = do
  when
    (ByteString.length bytes > executionJournalMaximumBytes)
    ( Left
        ( AwsAdminExecutionJournalTooLarge
            (ByteString.length bytes)
            executionJournalMaximumBytes
        )
    )
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminExecutionJournalDecodeFailed
    Right value -> Right value
  unless
    (wireJournalVersion wire == executionJournalVersion)
    (Left (AwsAdminExecutionJournalUnsupportedVersion (wireJournalVersion wire)))
  somePermit <-
    either
      (const (Left AwsAdminExecutionJournalInvalid))
      Right
      (decodeSignedAwsAdminPermit (wireJournalPermit wire))
  withSomeSignedAwsAdminPermit somePermit $ \permit -> do
    phase <- phaseFromWire (wireJournalPhase wire)
    let journal = AwsAdminExecutionJournal permit phase
    unless
      (encodeAwsAdminExecutionJournal journal == bytes)
      (Left AwsAdminExecutionJournalNonCanonical)
    pure journal

journalToWire :: AwsAdminExecutionJournal -> WireExecutionJournal
journalToWire journal =
  WireExecutionJournal
    { wireJournalVersion = executionJournalVersion
    , wireJournalPermit = encodeSignedAwsAdminPermit (awsAdminExecutionJournalPermit journal)
    , wireJournalPhase = phaseToWire (awsAdminExecutionJournalPhase journal)
    }

phaseToWire :: AwsAdminExecutionPhase -> WireExecutionPhase
phaseToWire phase = case phase of
  AwsAdminExecutionIntentCommitted used -> emptyPhase 1 used
  AwsAdminExecutionCreateAttemptPrepared predecessors used ->
    (emptyPhase 2 used) {wirePhasePredecessorKeyIds = keyText <$> predecessors}
  AwsAdminExecutionKeyCreated key predecessors used ->
    (emptyPhase 3 used)
      { wirePhaseKeyId = Just (keyText key)
      , wirePhasePredecessorKeyIds = keyText <$> predecessors
      }
  AwsAdminExecutionTargetCommitted key predecessors receipt used ->
    (emptyPhase 4 used)
      { wirePhaseKeyId = Just (keyText key)
      , wirePhasePredecessorKeyIds = keyText <$> predecessors
      , wirePhaseTargetReceipt = Just (encodeTargetWorkerReceipt receipt)
      }
  AwsAdminExecutionCleanupRequired used -> emptyPhase 5 used
  AwsAdminExecutionCleanupProven used -> emptyPhase 6 used
  AwsAdminExecutionComplete receipt ->
    (emptyPhase 7 False)
      { wirePhaseWorkerReceipt = Just receipt
      }

emptyPhase :: Word8 -> Bool -> WireExecutionPhase
emptyPhase tag used =
  WireExecutionPhase
    { wirePhaseTag = tag
    , wirePhaseKeyId = Nothing
    , wirePhasePredecessorKeyIds = []
    , wirePhaseRecoveryUsed = used
    , wirePhaseTargetReceipt = Nothing
    , wirePhaseWorkerReceipt = Nothing
    }

phaseFromWire
  :: WireExecutionPhase -> Either AwsAdminExecutionJournalError AwsAdminExecutionPhase
phaseFromWire wire = do
  key <- traverse keyFromText (wirePhaseKeyId wire)
  predecessors <- traverse keyFromText (wirePhasePredecessorKeyIds wire)
  targetReceipt <-
    traverse
      (either (const (Left AwsAdminExecutionJournalInvalid)) Right . decodeTargetWorkerReceipt)
      (wirePhaseTargetReceipt wire)
  let workerReceipt = wirePhaseWorkerReceipt wire
  phase <- case wirePhaseTag wire of
    1
      | emptyFields key predecessors targetReceipt workerReceipt ->
          Right (AwsAdminExecutionIntentCommitted used)
    2
      | key == Nothing && targetReceipt == Nothing && workerReceipt == Nothing ->
          Right (AwsAdminExecutionCreateAttemptPrepared predecessors used)
    3
      | targetReceipt == Nothing && workerReceipt == Nothing ->
          maybe
            (Left AwsAdminExecutionJournalInvalid)
            (\value -> Right (AwsAdminExecutionKeyCreated value predecessors used))
            key
    4 | workerReceipt == Nothing -> case (key, targetReceipt) of
      (Just value, Just receipt) ->
        Right (AwsAdminExecutionTargetCommitted value predecessors receipt used)
      _ -> Left AwsAdminExecutionJournalInvalid
    5
      | emptyFields key predecessors targetReceipt workerReceipt ->
          Right (AwsAdminExecutionCleanupRequired used)
    6
      | emptyFields key predecessors targetReceipt workerReceipt ->
          Right (AwsAdminExecutionCleanupProven used)
    7 | key == Nothing && null predecessors && targetReceipt == Nothing && not used ->
      case workerReceipt of
        Just receipt
          | not (ByteString.null receipt) && ByteString.length receipt <= 32 * 1024 ->
              Right (AwsAdminExecutionComplete receipt)
        _ -> Left AwsAdminExecutionJournalInvalid
    _ -> Left AwsAdminExecutionJournalInvalid
  unless (phaseToWire phase == wire) (Left AwsAdminExecutionJournalNonCanonical)
  pure phase
 where
  used = wirePhaseRecoveryUsed wire

emptyFields
  :: Maybe ProvisionedAccessKeyId
  -> [ProvisionedAccessKeyId]
  -> Maybe TargetWorkerReceipt
  -> Maybe ByteString
  -> Bool
emptyFields key predecessors targetReceipt workerReceipt =
  key == Nothing
    && null predecessors
    && targetReceipt == Nothing
    && workerReceipt == Nothing

keyFromText :: Text -> Either AwsAdminExecutionJournalError ProvisionedAccessKeyId
keyFromText =
  either (const (Left AwsAdminExecutionJournalInvalid)) Right . mkProvisionedAccessKeyId

keyText :: ProvisionedAccessKeyId -> Text
keyText = provisionedAccessKeyIdText
