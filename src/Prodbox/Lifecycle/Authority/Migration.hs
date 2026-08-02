{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pure single-writer authority-epoch migration. There is deliberately no
-- reachable state in which legacy and replacement writers are both active.
module Prodbox.Lifecycle.Authority.Migration
  ( AuthorityWriter (..)
  , MigrationBinding (..)
  , MigrationProjection (..)
  , MigrationProjectionImport (..)
  , MigrationDigest
  , MigrationEpoch
  , migrationEpochValue
  , MigrationPredecessor (..)
  , MigrationAuthorityStatus (..)
  , MigrationState
  , MigrationCommand (..)
  , MigrationDecision (..)
  , MigrationEvent
  , MigrationRefusal (..)
  , MigrationImportCommand (..)
  , MigrationImportDecision (..)
  , MigrationImportRefusal (..)
  , MigrationForwardCommand (..)
  , MigrationForwardDecision (..)
  , MigrationForwardRefusal (..)
  , initialMigrationState
  , initialImportingMigrationState
  , mkMigrationDigest
  , mkMigrationEpoch
  , activeWriter
  , migrationAuthorityStatus
  , migrationPredecessor
  , migrationProjectionImports
  , requiredMigrationProjections
  , decideMigration
  , stepMigration
  , decideMigrationImport
  , stepMigrationImport
  , decideForwardMigration
  , stepForwardMigration
  , MigrationCodecError (..)
  , encodeMigrationState
  , decodeMigrationState
  , encodeMigrationCommand
  , decodeMigrationCommand
  , encodeMigrationImportCommand
  , decodeMigrationImportCommand
  , encodeMigrationForwardCommand
  , decodeMigrationForwardCommand
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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

-- | The finite legacy projection inventory imported before the first authority
-- cutover. The import command records canonical-codec evidence; the production
-- importer remains responsible for decoding and copying the corresponding
-- projection bytes before recording that evidence.
data MigrationProjection
  = LeaseProjection
  | CheckpointProjection
  | TargetIntentProjection
  | SmtpProjection
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

-- | A bounded, typed observation of one legacy projection. Digests bind the
-- canonical versioned bytes observed/read back by the importer. A staged
-- projection binds both its committed and staged values; a released predecessor
-- binds the predecessor needed for safe successor recovery.
data MigrationProjectionImport
  = ProjectionMissing
  | ProjectionLegacy !MigrationDigest
  | ProjectionStaged !MigrationDigest !MigrationDigest
  | ProjectionReleasedPredecessor !MigrationDigest
  deriving stock (Eq, Show, Generic)
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
  | LegacyImportsObserved !(Map MigrationProjection MigrationProjectionImport)
  | LegacyImportsReady !(Map MigrationProjection MigrationProjectionImport)
  | ImportedShadowVerified
      !MigrationDigest
      !(Map MigrationProjection MigrationProjectionImport)
  | ImportedWritersFrozen
      !MigrationDigest
      !(Set MigrationBinding)
      !(Map MigrationProjection MigrationProjectionImport)
  | ImportedReplacementActive
      !MigrationDigest
      !MigrationEpoch
      !(Map MigrationProjection MigrationProjectionImport)
  | ForwardShadowVerified
      !MigrationDigest
      !MigrationEpoch
      !MigrationEpoch
      !(Map MigrationProjection MigrationProjectionImport)
  | ForwardWritersFrozen
      !MigrationDigest
      !MigrationEpoch
      !MigrationEpoch
      !(Set MigrationBinding)
      !(Map MigrationProjection MigrationProjectionImport)
  | ForwardReplacementActive
      !MigrationDigest
      !MigrationEpoch
      !MigrationEpoch
      !(Map MigrationProjection MigrationProjectionImport)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The writer generation that must be quiesced before activation.
data MigrationPredecessor
  = OriginalLegacyPredecessor
  | ReleasedReplacementPredecessor !MigrationEpoch
  deriving stock (Eq, Show)

data MigrationCommand
  = VerifyShadow !MigrationDigest
  | FreezeLegacy !MigrationDigest
  | PrepareBinding !MigrationBinding
  | ActivateReplacement !MigrationEpoch
  | RequestLegacyRollback
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Import commands use a distinct endpoint/caller boundary from migration
-- commands. This prevents a generic migration request from smuggling arbitrary
-- legacy payloads while still sharing the exact durable CAS state.
data MigrationImportCommand
  = RecordProjectionImport
      !MigrationProjection
      !MigrationProjectionImport
  | CompleteProjectionImports
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data MigrationImportRefusal
  = MigrationImportClosed
  | MigrationImportConflict !MigrationProjection
  | MigrationImportsMissing !(Set MigrationProjection)
  deriving stock (Eq, Show)

data MigrationImportDecision
  = MigrationImportAccepted
  | MigrationImportAlreadyApplied
  | MigrationImportRefused !MigrationImportRefusal
  deriving stock (Eq, Show)

-- | Forward recovery from an active replacement declares its target epoch
-- before the predecessor is frozen. This makes a same-digest epoch rotation
-- possible without making direct activation or legacy rollback possible.
data MigrationForwardCommand
  = BeginForwardMigration !MigrationDigest !MigrationEpoch
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data MigrationForwardRefusal
  = ForwardMigrationRequiresActiveReplacement
  | ForwardMigrationEpochMustAdvance
  | ForwardMigrationConflict
  deriving stock (Eq, Show)

data MigrationForwardDecision
  = ForwardMigrationAccepted
  | ForwardMigrationAlreadyApplied
  | ForwardMigrationRefused !MigrationForwardRefusal
  deriving stock (Eq, Show)

data MigrationEvent
  = ShadowVerificationRecorded !MigrationDigest
  | LegacyWriterFrozen
  | ReplacementPredecessorFrozen
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

-- | Initial state for the authority-epoch replacement protocol.  Unlike the
-- historical compatibility initializer, this state makes the four-member
-- projection import inventory a structural prerequisite for shadow
-- verification and freeze.  Production migration must use this constructor;
-- 'initialMigrationState' remains only for byte-compatible legacy fixtures.
initialImportingMigrationState :: MigrationState
initialImportingMigrationState = LegacyImportsObserved Map.empty

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

migrationEpochValue :: MigrationEpoch -> Word
migrationEpochValue (MigrationEpoch value) = value

-- | The externally observable writer/epoch projection.  It deliberately does
-- not expose the migration state's internal constructors or prepared-binding
-- set: callers such as Gateway DNS need only decide whether mutation is
-- currently admitted and, when it is, which one authority epoch owns it.
data MigrationAuthorityStatus
  = MigrationLegacyWriterActive
  | MigrationWritersQuiesced
  | MigrationReplacementWriterActive !MigrationEpoch
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Project every reachable migration state onto exactly one writer status.
-- A forward shadow keeps the predecessor replacement epoch active until its
-- explicit freeze; a forward freeze admits no writer; activation exposes only
-- the strictly greater successor epoch.
migrationAuthorityStatus :: MigrationState -> MigrationAuthorityStatus
migrationAuthorityStatus state = case state of
  LegacyActive -> MigrationLegacyWriterActive
  ShadowVerified _ -> MigrationLegacyWriterActive
  WritersFrozen _ _ -> MigrationWritersQuiesced
  ReplacementActive _ epoch -> MigrationReplacementWriterActive epoch
  LegacyImportsObserved _ -> MigrationLegacyWriterActive
  LegacyImportsReady _ -> MigrationLegacyWriterActive
  ImportedShadowVerified _ _ -> MigrationLegacyWriterActive
  ImportedWritersFrozen {} -> MigrationWritersQuiesced
  ImportedReplacementActive _ epoch _ -> MigrationReplacementWriterActive epoch
  ForwardShadowVerified _ predecessor _ _ -> MigrationReplacementWriterActive predecessor
  ForwardWritersFrozen {} -> MigrationWritersQuiesced
  ForwardReplacementActive _ epoch _ _ -> MigrationReplacementWriterActive epoch

activeWriter :: MigrationState -> Maybe AuthorityWriter
activeWriter state = case state of
  LegacyActive -> Just LegacyWriter
  ShadowVerified _ -> Just LegacyWriter
  WritersFrozen _ _ -> Nothing
  ReplacementActive _ _ -> Just ReplacementWriter
  LegacyImportsObserved _ -> Just LegacyWriter
  LegacyImportsReady _ -> Just LegacyWriter
  ImportedShadowVerified _ _ -> Just LegacyWriter
  ImportedWritersFrozen {} -> Nothing
  ImportedReplacementActive {} -> Just ReplacementWriter
  ForwardShadowVerified {} -> Just ReplacementWriter
  ForwardWritersFrozen {} -> Nothing
  ForwardReplacementActive {} -> Just ReplacementWriter

migrationPredecessor :: MigrationState -> MigrationPredecessor
migrationPredecessor state = case state of
  ReplacementActive _ epoch -> ReleasedReplacementPredecessor epoch
  ImportedReplacementActive _ epoch _ -> ReleasedReplacementPredecessor epoch
  ForwardShadowVerified _ predecessor _ _ -> ReleasedReplacementPredecessor predecessor
  ForwardWritersFrozen _ predecessor _ _ _ -> ReleasedReplacementPredecessor predecessor
  ForwardReplacementActive _ epoch _ _ -> ReleasedReplacementPredecessor epoch
  _ -> OriginalLegacyPredecessor

migrationProjectionImports
  :: MigrationState
  -> Map MigrationProjection MigrationProjectionImport
migrationProjectionImports state = case state of
  LegacyImportsObserved imports -> imports
  LegacyImportsReady imports -> imports
  ImportedShadowVerified _ imports -> imports
  ImportedWritersFrozen _ _ imports -> imports
  ImportedReplacementActive _ _ imports -> imports
  ForwardShadowVerified _ _ _ imports -> imports
  ForwardWritersFrozen _ _ _ _ imports -> imports
  ForwardReplacementActive _ _ _ imports -> imports
  _ -> Map.empty

decideMigration :: MigrationState -> MigrationCommand -> MigrationDecision
decideMigration state command = case command of
  VerifyShadow digest -> decideShadowVerification state digest
  FreezeLegacy digest -> decideWriterFreeze state digest
  PrepareBinding binding -> decideBindingPreparation state binding
  ActivateReplacement epoch -> decideReplacementActivation state epoch
  RequestLegacyRollback -> MigrationRefused LegacyRollbackForbidden

decideShadowVerification :: MigrationState -> MigrationDigest -> MigrationDecision
decideShadowVerification state digest = case state of
  LegacyActive -> MigrationAccepted [ShadowVerificationRecorded digest]
  LegacyImportsReady _ -> MigrationAccepted [ShadowVerificationRecorded digest]
  LegacyImportsObserved _ -> MigrationRefused ShadowDigestConflict
  ShadowVerified current -> replayOrShadowConflict current digest
  WritersFrozen current _ -> replayOrShadowConflict current digest
  ReplacementActive current _ -> replayOrShadowConflict current digest
  ImportedShadowVerified current _ -> replayOrShadowConflict current digest
  ImportedWritersFrozen current _ _ -> replayOrShadowConflict current digest
  ImportedReplacementActive current _ _ -> replayOrShadowConflict current digest
  ForwardShadowVerified current _ _ _ -> replayOrShadowConflict current digest
  ForwardWritersFrozen current _ _ _ _ -> replayOrShadowConflict current digest
  ForwardReplacementActive current _ _ _ -> replayOrShadowConflict current digest

replayOrShadowConflict :: MigrationDigest -> MigrationDigest -> MigrationDecision
replayOrShadowConflict current requested
  | current == requested = MigrationAlreadyApplied
  | otherwise = MigrationRefused ShadowDigestConflict

decideWriterFreeze :: MigrationState -> MigrationDigest -> MigrationDecision
decideWriterFreeze state digest = case state of
  ShadowVerified current
    | current == digest -> MigrationAccepted [LegacyWriterFrozen]
    | otherwise -> MigrationRefused FreezeDigestConflict
  ImportedShadowVerified current _
    | current == digest -> MigrationAccepted [LegacyWriterFrozen]
    | otherwise -> MigrationRefused FreezeDigestConflict
  ForwardShadowVerified current _ _ _
    | current == digest -> MigrationAccepted [ReplacementPredecessorFrozen]
    | otherwise -> MigrationRefused FreezeDigestConflict
  WritersFrozen current _ -> replayOrFreezeConflict current digest
  ImportedWritersFrozen current _ _ -> replayOrFreezeConflict current digest
  ForwardWritersFrozen current _ _ _ _ -> replayOrFreezeConflict current digest
  ReplacementActive current _ -> replayOrFreezeConflict current digest
  ImportedReplacementActive current _ _ -> replayOrFreezeConflict current digest
  ForwardReplacementActive current _ _ _ -> replayOrFreezeConflict current digest
  _ -> MigrationRefused FreezeBeforeShadowVerification

replayOrFreezeConflict :: MigrationDigest -> MigrationDigest -> MigrationDecision
replayOrFreezeConflict current requested
  | current == requested = MigrationAlreadyApplied
  | otherwise = MigrationRefused FreezeDigestConflict

decideBindingPreparation :: MigrationState -> MigrationBinding -> MigrationDecision
decideBindingPreparation state binding =
  case preparedBindings state of
    Nothing -> MigrationRefused PrepareBeforeFreeze
    Just prepared
      | Set.member binding prepared -> MigrationAlreadyApplied
      | otherwise -> MigrationAccepted [BindingPrepared binding]

preparedBindings :: MigrationState -> Maybe (Set MigrationBinding)
preparedBindings state = case state of
  WritersFrozen _ prepared -> Just prepared
  ImportedWritersFrozen _ prepared _ -> Just prepared
  ForwardWritersFrozen _ _ _ prepared _ -> Just prepared
  _ -> Nothing

decideReplacementActivation :: MigrationState -> MigrationEpoch -> MigrationDecision
decideReplacementActivation state epoch = case state of
  WritersFrozen _ prepared -> requireBindings prepared epoch
  ImportedWritersFrozen _ prepared _ -> requireBindings prepared epoch
  ForwardWritersFrozen _ predecessor target prepared _
    | target <= predecessor -> MigrationRefused EpochMustAdvance
    | epoch /= target -> MigrationRefused EpochMustAdvance
    | otherwise -> requireBindings prepared epoch
  ReplacementActive _ currentEpoch -> activeEpochReplay currentEpoch epoch
  ImportedReplacementActive _ currentEpoch _ -> activeEpochReplay currentEpoch epoch
  ForwardReplacementActive _ currentEpoch _ _ -> activeEpochReplay currentEpoch epoch
  _ -> MigrationRefused ActivationBeforeFreeze

requireBindings :: Set MigrationBinding -> MigrationEpoch -> MigrationDecision
requireBindings prepared epoch
  | prepared /= requiredBindings =
      MigrationRefused (ActivationBindingsMissing (requiredBindings `Set.difference` prepared))
  | otherwise = MigrationAccepted [ReplacementActivated epoch]

activeEpochReplay :: MigrationEpoch -> MigrationEpoch -> MigrationDecision
activeEpochReplay current requested
  | requested == current = MigrationAlreadyApplied
  | requested < current = MigrationRefused EpochMustAdvance
  | otherwise = MigrationRefused ActivationBeforeFreeze

evolveMigration :: MigrationState -> MigrationEvent -> MigrationState
evolveMigration state event = case (state, event) of
  (LegacyActive, ShadowVerificationRecorded digest) -> ShadowVerified digest
  (LegacyImportsReady imports, ShadowVerificationRecorded digest) ->
    ImportedShadowVerified digest imports
  (ShadowVerified digest, LegacyWriterFrozen) -> WritersFrozen digest Set.empty
  (ImportedShadowVerified digest imports, LegacyWriterFrozen) ->
    ImportedWritersFrozen digest Set.empty imports
  (ForwardShadowVerified digest predecessor target imports, ReplacementPredecessorFrozen) ->
    ForwardWritersFrozen digest predecessor target Set.empty imports
  (WritersFrozen digest prepared, BindingPrepared binding) ->
    WritersFrozen digest (Set.insert binding prepared)
  (ImportedWritersFrozen digest prepared imports, BindingPrepared binding) ->
    ImportedWritersFrozen digest (Set.insert binding prepared) imports
  (ForwardWritersFrozen digest predecessor target prepared imports, BindingPrepared binding) ->
    ForwardWritersFrozen digest predecessor target (Set.insert binding prepared) imports
  (WritersFrozen digest _, ReplacementActivated epoch) ->
    ReplacementActive digest epoch
  (ImportedWritersFrozen digest _ imports, ReplacementActivated epoch) ->
    ImportedReplacementActive digest epoch imports
  (ForwardWritersFrozen digest predecessor _ _ imports, ReplacementActivated epoch) ->
    ForwardReplacementActive digest epoch predecessor imports
  _ -> state

stepMigration :: MigrationState -> MigrationCommand -> (MigrationState, MigrationDecision)
stepMigration state command =
  case decideMigration state command of
    decision@(MigrationAccepted events) -> (foldl evolveMigration state events, decision)
    decision -> (state, decision)

decideMigrationImport :: MigrationState -> MigrationImportCommand -> MigrationImportDecision
decideMigrationImport state command = case command of
  RecordProjectionImport projection imported ->
    case Map.lookup projection (migrationProjectionImports state) of
      Just current
        | current == imported -> MigrationImportAlreadyApplied
        | otherwise -> MigrationImportRefused (MigrationImportConflict projection)
      Nothing
        | acceptsProjectionImports state -> MigrationImportAccepted
        | otherwise -> MigrationImportRefused MigrationImportClosed
  CompleteProjectionImports ->
    let imports = migrationProjectionImports state
        missing = requiredMigrationProjections `Set.difference` Map.keysSet imports
     in if canCompleteProjectionImports state
          then
            if Set.null missing
              then MigrationImportAccepted
              else MigrationImportRefused (MigrationImportsMissing missing)
          else
            if carriesCompletedProjectionImports state
              then MigrationImportAlreadyApplied
              else
                MigrationImportRefused MigrationImportClosed

stepMigrationImport
  :: MigrationState
  -> MigrationImportCommand
  -> (MigrationState, MigrationImportDecision)
stepMigrationImport state command =
  case decideMigrationImport state command of
    MigrationImportAccepted -> (evolveMigrationImport state command, MigrationImportAccepted)
    decision -> (state, decision)

evolveMigrationImport :: MigrationState -> MigrationImportCommand -> MigrationState
evolveMigrationImport state command = case (state, command) of
  (LegacyActive, RecordProjectionImport projection imported) ->
    LegacyImportsObserved (Map.singleton projection imported)
  (LegacyImportsObserved imports, RecordProjectionImport projection imported) ->
    LegacyImportsObserved (Map.insert projection imported imports)
  (LegacyImportsObserved imports, CompleteProjectionImports) -> LegacyImportsReady imports
  _ -> state

acceptsProjectionImports :: MigrationState -> Bool
acceptsProjectionImports state = case state of
  LegacyActive -> True
  LegacyImportsObserved _ -> True
  _ -> False

canCompleteProjectionImports :: MigrationState -> Bool
canCompleteProjectionImports state = case state of
  LegacyActive -> True
  LegacyImportsObserved _ -> True
  _ -> False

carriesCompletedProjectionImports :: MigrationState -> Bool
carriesCompletedProjectionImports state = case state of
  LegacyImportsReady _ -> True
  ImportedShadowVerified _ _ -> True
  ImportedWritersFrozen {} -> True
  ImportedReplacementActive {} -> True
  ForwardShadowVerified _ _ _ imports -> not (Map.null imports)
  ForwardWritersFrozen _ _ _ _ imports -> not (Map.null imports)
  ForwardReplacementActive _ _ _ imports -> not (Map.null imports)
  _ -> False

decideForwardMigration :: MigrationState -> MigrationForwardCommand -> MigrationForwardDecision
decideForwardMigration state (BeginForwardMigration digest target) = case state of
  ReplacementActive _ predecessor
    | target <= predecessor -> ForwardMigrationRefused ForwardMigrationEpochMustAdvance
    | otherwise -> ForwardMigrationAccepted
  ImportedReplacementActive _ predecessor _
    | target <= predecessor -> ForwardMigrationRefused ForwardMigrationEpochMustAdvance
    | otherwise -> ForwardMigrationAccepted
  ForwardReplacementActive current predecessor previous _
    | current == digest && target == predecessor -> ForwardMigrationAlreadyApplied
    | target <= predecessor -> ForwardMigrationRefused ForwardMigrationEpochMustAdvance
    | target <= previous -> ForwardMigrationRefused ForwardMigrationEpochMustAdvance
    | otherwise -> ForwardMigrationAccepted
  ForwardShadowVerified current _ currentTarget _ -> replayForward current currentTarget
  ForwardWritersFrozen current _ currentTarget _ _ -> replayForward current currentTarget
  _ -> ForwardMigrationRefused ForwardMigrationRequiresActiveReplacement
 where
  replayForward current currentTarget
    | current == digest && currentTarget == target = ForwardMigrationAlreadyApplied
    | otherwise = ForwardMigrationRefused ForwardMigrationConflict

stepForwardMigration
  :: MigrationState
  -> MigrationForwardCommand
  -> (MigrationState, MigrationForwardDecision)
stepForwardMigration state command@(BeginForwardMigration digest target) =
  case decideForwardMigration state command of
    ForwardMigrationAccepted ->
      case state of
        ReplacementActive _ predecessor ->
          (ForwardShadowVerified digest predecessor target Map.empty, ForwardMigrationAccepted)
        ImportedReplacementActive _ predecessor imports ->
          (ForwardShadowVerified digest predecessor target imports, ForwardMigrationAccepted)
        ForwardReplacementActive _ predecessor _ imports ->
          (ForwardShadowVerified digest predecessor target imports, ForwardMigrationAccepted)
        _ -> (state, ForwardMigrationRefused ForwardMigrationRequiresActiveReplacement)
    decision -> (state, decision)

requiredBindings :: Set MigrationBinding
requiredBindings = Set.fromList [minBound .. maxBound]

requiredMigrationProjections :: Set MigrationProjection
requiredMigrationProjections = Set.fromList [minBound .. maxBound]

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
currentMigrationEnvelopeVersion = 2

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
          | migrationEnvelopeVersion envelope `notElem` [1, currentMigrationEnvelopeVersion] ->
              Left MigrationEnvelopeUnsupportedVersion
          | serialise envelope /= bytes -> Left MigrationEnvelopeNonCanonical
          | migrationEnvelopeVersion envelope == 1
              && not (migrationStateSupportedByVersionOne (migrationEnvelopeState envelope)) ->
              Left MigrationEnvelopeInvalid
          | not (validMigrationState (migrationEnvelopeState envelope)) ->
              Left MigrationEnvelopeInvalid
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
          | not (validMigrationCommand (migrationCommandEnvelopeCommand envelope)) ->
              Left MigrationEnvelopeInvalid
          | otherwise -> Right (migrationCommandEnvelopeCommand envelope)

data MigrationImportCommandEnvelope = MigrationImportCommandEnvelope
  { migrationImportCommandEnvelopeVersion :: !Word
  , migrationImportCommandEnvelopeCommand :: !MigrationImportCommand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentMigrationImportCommandEnvelopeVersion :: Word
currentMigrationImportCommandEnvelopeVersion = 1

encodeMigrationImportCommand :: MigrationImportCommand -> ByteString
encodeMigrationImportCommand command =
  serialise
    MigrationImportCommandEnvelope
      { migrationImportCommandEnvelopeVersion = currentMigrationImportCommandEnvelopeVersion
      , migrationImportCommandEnvelopeCommand = command
      }

decodeMigrationImportCommand
  :: Int
  -> ByteString
  -> Either MigrationCodecError MigrationImportCommand
decodeMigrationImportCommand maximumBytes bytes
  | maximumBytes < 0 = Left MigrationEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left MigrationEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left MigrationEnvelopeInvalid
        Right envelope
          | migrationImportCommandEnvelopeVersion envelope
              /= currentMigrationImportCommandEnvelopeVersion ->
              Left MigrationEnvelopeUnsupportedVersion
          | serialise envelope /= bytes -> Left MigrationEnvelopeNonCanonical
          | not (validMigrationImportCommand (migrationImportCommandEnvelopeCommand envelope)) ->
              Left MigrationEnvelopeInvalid
          | otherwise -> Right (migrationImportCommandEnvelopeCommand envelope)

data MigrationForwardCommandEnvelope = MigrationForwardCommandEnvelope
  { migrationForwardCommandEnvelopeVersion :: !Word
  , migrationForwardCommandEnvelopeCommand :: !MigrationForwardCommand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentMigrationForwardCommandEnvelopeVersion :: Word
currentMigrationForwardCommandEnvelopeVersion = 1

encodeMigrationForwardCommand :: MigrationForwardCommand -> ByteString
encodeMigrationForwardCommand command =
  serialise
    MigrationForwardCommandEnvelope
      { migrationForwardCommandEnvelopeVersion = currentMigrationForwardCommandEnvelopeVersion
      , migrationForwardCommandEnvelopeCommand = command
      }

decodeMigrationForwardCommand
  :: Int
  -> ByteString
  -> Either MigrationCodecError MigrationForwardCommand
decodeMigrationForwardCommand maximumBytes bytes
  | maximumBytes < 0 = Left MigrationEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left MigrationEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left MigrationEnvelopeInvalid
        Right envelope
          | migrationForwardCommandEnvelopeVersion envelope
              /= currentMigrationForwardCommandEnvelopeVersion ->
              Left MigrationEnvelopeUnsupportedVersion
          | serialise envelope /= bytes -> Left MigrationEnvelopeNonCanonical
          | not (validMigrationForwardCommand (migrationForwardCommandEnvelopeCommand envelope)) ->
              Left MigrationEnvelopeInvalid
          | otherwise -> Right (migrationForwardCommandEnvelopeCommand envelope)

migrationStateSupportedByVersionOne :: MigrationState -> Bool
migrationStateSupportedByVersionOne state = case state of
  LegacyActive -> True
  ShadowVerified _ -> True
  WritersFrozen _ _ -> True
  ReplacementActive _ _ -> True
  _ -> False

validMigrationState :: MigrationState -> Bool
validMigrationState state = case state of
  LegacyActive -> True
  ShadowVerified digest -> validMigrationDigest digest
  WritersFrozen digest _ -> validMigrationDigest digest
  ReplacementActive digest epoch -> validMigrationDigest digest && validMigrationEpoch epoch
  LegacyImportsObserved imports -> not (Map.null imports) && validProjectionImports imports
  LegacyImportsReady imports -> completeProjectionImports imports
  ImportedShadowVerified digest imports ->
    validMigrationDigest digest && completeProjectionImports imports
  ImportedWritersFrozen digest _ imports ->
    validMigrationDigest digest && completeProjectionImports imports
  ImportedReplacementActive digest epoch imports ->
    validMigrationDigest digest
      && validMigrationEpoch epoch
      && completeProjectionImports imports
  ForwardShadowVerified digest predecessor target imports ->
    validForwardState digest predecessor target imports
  ForwardWritersFrozen digest predecessor target _ imports ->
    validForwardState digest predecessor target imports
  ForwardReplacementActive digest epoch predecessor imports ->
    validForwardState digest predecessor epoch imports

validForwardState
  :: MigrationDigest
  -> MigrationEpoch
  -> MigrationEpoch
  -> Map MigrationProjection MigrationProjectionImport
  -> Bool
validForwardState digest predecessor target imports =
  validMigrationDigest digest
    && validMigrationEpoch predecessor
    && validMigrationEpoch target
    && target > predecessor
    && (Map.null imports || completeProjectionImports imports)

validProjectionImports
  :: Map MigrationProjection MigrationProjectionImport
  -> Bool
validProjectionImports imports =
  Map.keysSet imports `Set.isSubsetOf` requiredMigrationProjections
    && all validMigrationProjectionImport (Map.elems imports)

completeProjectionImports
  :: Map MigrationProjection MigrationProjectionImport
  -> Bool
completeProjectionImports imports =
  Map.keysSet imports == requiredMigrationProjections
    && validProjectionImports imports

validMigrationProjectionImport :: MigrationProjectionImport -> Bool
validMigrationProjectionImport imported = case imported of
  ProjectionMissing -> True
  ProjectionLegacy digest -> validMigrationDigest digest
  ProjectionStaged committed staged ->
    validMigrationDigest committed && validMigrationDigest staged
  ProjectionReleasedPredecessor digest -> validMigrationDigest digest

validMigrationCommand :: MigrationCommand -> Bool
validMigrationCommand command = case command of
  VerifyShadow digest -> validMigrationDigest digest
  FreezeLegacy digest -> validMigrationDigest digest
  PrepareBinding _ -> True
  ActivateReplacement epoch -> validMigrationEpoch epoch
  RequestLegacyRollback -> True

validMigrationImportCommand :: MigrationImportCommand -> Bool
validMigrationImportCommand command = case command of
  RecordProjectionImport _ imported -> validMigrationProjectionImport imported
  CompleteProjectionImports -> True

validMigrationForwardCommand :: MigrationForwardCommand -> Bool
validMigrationForwardCommand (BeginForwardMigration digest target) =
  validMigrationDigest digest && validMigrationEpoch target

validMigrationDigest :: MigrationDigest -> Bool
validMigrationDigest digest@(MigrationDigest value) = mkMigrationDigest value == Just digest

validMigrationEpoch :: MigrationEpoch -> Bool
validMigrationEpoch epoch@(MigrationEpoch value) = mkMigrationEpoch value == Just epoch
