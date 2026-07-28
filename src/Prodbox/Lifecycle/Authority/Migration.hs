{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pure single-writer authority-epoch migration. There is deliberately no
-- reachable state in which legacy and replacement writers are both active.
module Prodbox.Lifecycle.Authority.Migration
  ( AuthorityWriter (..)
  , MigrationBinding (..)
  , MigrationDigest
  , MigrationEpoch
  , MigrationState
  , MigrationCommand (..)
  , MigrationDecision (..)
  , MigrationEvent
  , MigrationRefusal (..)
  , initialMigrationState
  , mkMigrationDigest
  , mkMigrationEpoch
  , activeWriter
  , decideMigration
  , stepMigration
  , MigrationCodecError (..)
  , encodeMigrationState
  , decodeMigrationState
  , encodeMigrationCommand
  , decodeMigrationCommand
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

data AuthorityWriter = LegacyWriter | ReplacementWriter
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data MigrationBinding
  = AuthorityStoreBinding
  | AuthorityBackupBinding
  | ProviderWorkerBinding
  | TargetAgentBinding
  | GatewayDnsBinding
  | TlsRetentionBinding
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

newtype MigrationDigest = MigrationDigest Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype MigrationEpoch = MigrationEpoch Word
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data MigrationState
  = LegacyActive
  | ShadowVerified !MigrationDigest
  | WritersFrozen !MigrationDigest !(Set MigrationBinding)
  | ReplacementActive !MigrationDigest !MigrationEpoch
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data MigrationCommand
  = VerifyShadow !MigrationDigest
  | FreezeLegacy !MigrationDigest
  | PrepareBinding !MigrationBinding
  | ActivateReplacement !MigrationEpoch
  | RequestLegacyRollback
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data MigrationEvent
  = ShadowVerificationRecorded !MigrationDigest
  | LegacyWriterFrozen
  | BindingPrepared !MigrationBinding
  | ReplacementActivated !MigrationEpoch
  deriving stock (Eq, Show)

data MigrationRefusal
  = ShadowDigestConflict
  | FreezeBeforeShadowVerification
  | FreezeDigestConflict
  | PrepareBeforeFreeze
  | ActivationBeforeFreeze
  | ActivationBindingsMissing !(Set MigrationBinding)
  | EpochMustAdvance
  | LegacyRollbackForbidden
  deriving stock (Eq, Show)

data MigrationDecision
  = MigrationAccepted ![MigrationEvent]
  | MigrationAlreadyApplied
  | MigrationRefused !MigrationRefusal
  deriving stock (Eq, Show)

initialMigrationState :: MigrationState
initialMigrationState = LegacyActive

mkMigrationDigest :: Text -> Maybe MigrationDigest
mkMigrationDigest value
  | Text.null value = Nothing
  | Text.length value > 128 = Nothing
  | Text.any isControl value = Nothing
  | otherwise = Just (MigrationDigest value)

mkMigrationEpoch :: Word -> Maybe MigrationEpoch
mkMigrationEpoch value
  | value == 0 = Nothing
  | otherwise = Just (MigrationEpoch value)

activeWriter :: MigrationState -> Maybe AuthorityWriter
activeWriter state = case state of
  LegacyActive -> Just LegacyWriter
  ShadowVerified _ -> Just LegacyWriter
  WritersFrozen _ _ -> Nothing
  ReplacementActive _ _ -> Just ReplacementWriter

decideMigration :: MigrationState -> MigrationCommand -> MigrationDecision
decideMigration state command = case (state, command) of
  (LegacyActive, VerifyShadow digest) ->
    MigrationAccepted [ShadowVerificationRecorded digest]
  (ShadowVerified current, VerifyShadow digest)
    | current == digest -> MigrationAlreadyApplied
    | otherwise -> MigrationRefused ShadowDigestConflict
  (WritersFrozen current _, VerifyShadow digest)
    | current == digest -> MigrationAlreadyApplied
    | otherwise -> MigrationRefused ShadowDigestConflict
  (ReplacementActive current _, VerifyShadow digest)
    | current == digest -> MigrationAlreadyApplied
    | otherwise -> MigrationRefused ShadowDigestConflict
  (LegacyActive, FreezeLegacy _) ->
    MigrationRefused FreezeBeforeShadowVerification
  (ShadowVerified current, FreezeLegacy digest)
    | current == digest -> MigrationAccepted [LegacyWriterFrozen]
    | otherwise -> MigrationRefused FreezeDigestConflict
  (WritersFrozen current _, FreezeLegacy digest)
    | current == digest -> MigrationAlreadyApplied
    | otherwise -> MigrationRefused FreezeDigestConflict
  (ReplacementActive _ _, FreezeLegacy _) -> MigrationAlreadyApplied
  (WritersFrozen _ prepared, PrepareBinding binding)
    | Set.member binding prepared -> MigrationAlreadyApplied
    | otherwise -> MigrationAccepted [BindingPrepared binding]
  (_, PrepareBinding _) -> MigrationRefused PrepareBeforeFreeze
  (WritersFrozen _ prepared, ActivateReplacement epoch)
    | prepared /= requiredBindings ->
        MigrationRefused (ActivationBindingsMissing (requiredBindings `Set.difference` prepared))
    | otherwise -> MigrationAccepted [ReplacementActivated epoch]
  (ReplacementActive _ currentEpoch, ActivateReplacement epoch)
    | currentEpoch == epoch -> MigrationAlreadyApplied
    | otherwise -> MigrationRefused EpochMustAdvance
  (_, ActivateReplacement _) -> MigrationRefused ActivationBeforeFreeze
  (_, RequestLegacyRollback) -> MigrationRefused LegacyRollbackForbidden

evolveMigration :: MigrationState -> MigrationEvent -> MigrationState
evolveMigration state event = case (state, event) of
  (LegacyActive, ShadowVerificationRecorded digest) -> ShadowVerified digest
  (ShadowVerified digest, LegacyWriterFrozen) -> WritersFrozen digest Set.empty
  (WritersFrozen digest prepared, BindingPrepared binding) ->
    WritersFrozen digest (Set.insert binding prepared)
  (WritersFrozen digest _, ReplacementActivated epoch) ->
    ReplacementActive digest epoch
  _ -> state

stepMigration :: MigrationState -> MigrationCommand -> (MigrationState, MigrationDecision)
stepMigration state command =
  case decideMigration state command of
    decision@(MigrationAccepted events) -> (foldl evolveMigration state events, decision)
    decision -> (state, decision)

requiredBindings :: Set MigrationBinding
requiredBindings = Set.fromList [minBound .. maxBound]

data MigrationCodecError
  = MigrationEnvelopeTooLarge
  | MigrationEnvelopeInvalid
  | MigrationEnvelopeUnsupportedVersion
  | MigrationEnvelopeNonCanonical
  deriving stock (Eq, Show)

data MigrationEnvelope = MigrationEnvelope
  { migrationEnvelopeVersion :: !Word
  , migrationEnvelopeState :: !MigrationState
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentMigrationEnvelopeVersion :: Word
currentMigrationEnvelopeVersion = 1

encodeMigrationState :: MigrationState -> ByteString
encodeMigrationState state =
  serialise
    MigrationEnvelope
      { migrationEnvelopeVersion = currentMigrationEnvelopeVersion
      , migrationEnvelopeState = state
      }

decodeMigrationState :: Int -> ByteString -> Either MigrationCodecError MigrationState
decodeMigrationState maximumBytes bytes
  | maximumBytes < 0 = Left MigrationEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left MigrationEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left MigrationEnvelopeInvalid
        Right envelope
          | migrationEnvelopeVersion envelope /= currentMigrationEnvelopeVersion ->
              Left MigrationEnvelopeUnsupportedVersion
          | serialise envelope /= bytes -> Left MigrationEnvelopeNonCanonical
          | otherwise -> Right (migrationEnvelopeState envelope)

-- | The request-side counterpart of the state envelope: a 'MigrationCommand'
-- submitted to the Lifecycle Authority migration-apply route carries the exact
-- same versioned, bounded, canonical framing so a corrupt, oversized, or
-- non-canonical request body is refused before it can reach 'decideMigration'.
data MigrationCommandEnvelope = MigrationCommandEnvelope
  { migrationCommandEnvelopeVersion :: !Word
  , migrationCommandEnvelopeCommand :: !MigrationCommand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentMigrationCommandEnvelopeVersion :: Word
currentMigrationCommandEnvelopeVersion = 1

encodeMigrationCommand :: MigrationCommand -> ByteString
encodeMigrationCommand command =
  serialise
    MigrationCommandEnvelope
      { migrationCommandEnvelopeVersion = currentMigrationCommandEnvelopeVersion
      , migrationCommandEnvelopeCommand = command
      }

decodeMigrationCommand :: Int -> ByteString -> Either MigrationCodecError MigrationCommand
decodeMigrationCommand maximumBytes bytes
  | maximumBytes < 0 = Left MigrationEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left MigrationEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left MigrationEnvelopeInvalid
        Right envelope
          | migrationCommandEnvelopeVersion envelope /= currentMigrationCommandEnvelopeVersion ->
              Left MigrationEnvelopeUnsupportedVersion
          | serialise envelope /= bytes -> Left MigrationEnvelopeNonCanonical
          | otherwise -> Right (migrationCommandEnvelopeCommand envelope)
