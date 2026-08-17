{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The single retained admission aggregate for the Lifecycle Authority.
--
-- Genesis, backup repair, writer migration, and operation submission share one
-- compare-and-swap object.  That physical composition is intentional: checking
-- an admission flag in one object and appending a submission to another leaves
-- a freeze/submit race.  The aggregate also retains the epoch that admitted
-- every submission identity.  An exact retry therefore returns the original
-- 'OperationId' after a repair or migration advances the active epoch.
module Prodbox.Lifecycle.Authority.Admission
  ( -- * Retained state
    AuthorityMigrationMode (..)
  , AuthorityDecommissionState (..)
  , AuthorityDecommissionDecision (..)
  , AuthorityAdmissionAggregate
  , AuthorityAdmissionConfigurationError (..)
  , AuthorityAdmissionInvariantError (..)
  , initialCleanInstallAuthority
  , initialMigratingAuthority
  , initialCleanInstallAuthorityWithRegisteredClients
  , initialMigratingAuthorityWithRegisteredClients
  , authorityAggregateAdmission
  , authorityAggregateMigration
  , authorityAggregateSubmissionLedger
  , authorityAggregateRetainedCapacity
  , authorityAggregateRegisteredClients
  , authorityAggregatePulumiCheckpoints
  , authorityAggregateConfig
  , authorityAggregateDecommission
  , authorityAggregateProviderAdmissionEpochView
  , authorityAggregateSubmissionEpoch
  , authorityAggregateSubmissionEpochBindings
  , authorityAggregateProviderOperations
  , validateAuthorityAdmissionAggregate
  , validateAuthorityAdmissionAggregateWithRegisteredClients

    -- * Admission gate
  , AuthoritySubmissionGateRefusal (..)
  , activeAuthorityEpoch
  , freezeAuthorityForDecommission
  , permanentlyStopAuthorityForDecommission

    -- * Authority transitions
  , AuthorityAdmissionCommand (..)
  , AuthorityAdmissionCommandRefusal (..)
  , AuthorityAdmissionDecision (..)
  , stepAuthorityAdmission

    -- * Operation submission
  , AuthoritySubmissionDecision (..)
  , decideAuthoritySubmission
  , stepAuthoritySubmission
  , authoritySubmissionStatus

    -- * In-force config
  , AuthorityConfigProposalDecision (..)
  , decideAuthorityConfigProposal
  , stepAuthorityConfigProposal

    -- * Registered-client production submission
  , AuthorityRegisteredSubmissionDecision (..)
  , decideRegisteredAuthoritySubmission
  , stepRegisteredAuthoritySubmission
  , observeRegisteredAuthoritySubmission

    -- * Retained Provider operations
  , AuthorityProviderOperation (..)
  , AuthorityProviderSubmissionDecision (..)
  , AuthorityProviderSettlementDecision (..)
  , stepRegisteredProviderSubmission
  , stepRegisteredProviderSettlement

    -- * Pulumi checkpoint projection
  , authorityCheckpointOperationRef
  , authorityCheckpointOperationStatus
  , stepAuthorityCheckpointPermit
  , stepAuthorityCheckpointPublication
  , stepAuthorityCheckpointRestore
  , stepAuthorityCheckpointRetirement
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise (Serialise (decode, encode), serialise)
import Control.Monad (unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal)
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupRepairCommand
  , BackupRepairDecision
  , stepBackupRepair
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , RegisteredClientGeneration
  , RegisteredClientTable
  , RegisteredClientTableError
  , RegisteredClientTableInvariantError
  , RegisteredSubmissionDecision (..)
  , RegisteredSubmissionInspection (..)
  , RegisteredSubmissionObservation
  , inspectRegisteredSubmission
  , mkRegisteredClientTable
  , observeRegisteredSubmission
  , registeredClientIdForCaller
  , registeredClientReservationBindings
  , registeredClientReservationEntries
  , registeredClientTableConfigurationMatches
  , reserveRegisteredSubmission
  , validateRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.Config
  ( ConfigProposal
  , ConfigProposeDecision
  , ConfigState
  , ConfigStateInvariantError
  , SchemaValidity
  , initialConfigState
  , stepConfigPropose
  , validateConfigState
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityEpoch
  , AuthorityGenesisCommand
  , GenesisDecision
  , authorityEpochFromValue
  , authorityEpochValue
  , initialGenesisState
  , stepGenesis
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , MigrationCommand
  , MigrationDecision (..)
  , MigrationForwardCommand
  , MigrationForwardDecision
  , MigrationImportCommand
  , MigrationImportDecision
  , MigrationState
  , initialImportingMigrationState
  , migrationAuthorityStatus
  , migrationEpochValue
  , stepForwardMigration
  , stepMigration
  , stepMigrationImport
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderAdmissionEpochView
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
  ( ProviderAdmissionEpoch
  , ProviderAdmissionEpochError
  , ProviderAdmissionFreshSubmissionRefusal (..)
  , initialLegacyProviderAdmissionEpochInternal
  , providerAdmissionEpochView
  , providerAdmissionFreshSubmissionRefusalInternal
  , validateProviderAdmissionEpochInternal
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( AuthorityPulumiCheckpointInvariantError
  , AuthorityPulumiCheckpoints
  , CheckpointMutationDecision (..)
  , CheckpointOperationKind
  , CheckpointPermitDecision (..)
  , VerifiedPulumiCheckpointRef
  , applyCheckpointPublication
  , applyCheckpointRestore
  , applyCheckpointRetirement
  , compactTerminalCheckpointOperation
  , initialAuthorityPulumiCheckpoints
  , registerCheckpointOperationPermit
  , validateAuthorityPulumiCheckpoints
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , ClientSubmissions (..)
  , OperationId (..)
  , RequestDigest (..)
  , SubmissionLedger (..)
  , SubmissionRecord (..)
  , SubmissionStatus (..)
  , SubmissionTransitionRefusal (..)
  , SubmitDecision (..)
  , TerminalOutcome (..)
  , compactClientTerminalsBelow
  , completeSubmission
  , emptySubmissionLedger
  , liveSubmissionCount
  , stepSubmit
  , submissionStatus
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest (FrameDigest))
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent)
import Prodbox.Lifecycle.PulumiCheckpoint
  ( PulumiCheckpointDigest
  , PulumiCheckpointOperationRef
  , PulumiCheckpointOperationRefError
  , RegisteredPulumiCheckpoint
  , mkPulumiCheckpointOperationRef
  )

-- | Whether this authority is a clean install or participates in the explicit
-- single-writer migration protocol.  A clean install has no legacy writer.  A
-- migration-controlled authority admits only when the migration projection says
-- the replacement writer is active; legacy-active and writers-quiesced states
-- are closed.
data AuthorityMigrationMode
  = AuthorityCleanInstall
  | AuthorityMigrationControlled !MigrationState
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The permanent total-decommission gate lives in the same retained object
-- as operation admission, so freezing and submitting cannot race.  The final
-- state binds both the authenticated manifest and the acknowledged external
-- receipt; there is deliberately no transition back to 'AuthorityServing'.
data AuthorityDecommissionState
  = AuthorityServing
  | AuthorityDecommissionFrozen
  | AuthorityPermanentlyStopped !FrameDigest !FrameDigest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityDecommissionDecision
  = AuthorityDecommissionFreezeApplied
  | AuthorityDecommissionFreezeAlreadyApplied
  | AuthorityDecommissionStopApplied
  | AuthorityDecommissionStopAlreadyApplied
  | AuthorityDecommissionFreezeRefusedAlreadyStopped
  | AuthorityDecommissionStopRefusedBeforeFreeze
  | AuthorityDecommissionStopRefusedBindingConflict
      !FrameDigest
      !FrameDigest
      !FrameDigest
      !FrameDigest
  deriving stock (Eq, Show)

-- | Exact Provider intent retained beside its registered submission.  A
-- completed record keeps bounded positive evidence so a response-loss retry
-- can return the durable outcome without inventing another operation.
data AuthorityProviderOperation
  = AuthorityProviderPending !RequestDigest !ProviderIntent
  | AuthorityProviderCompleted !RequestDigest !ProviderIntent !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityProviderOperationDigest :: AuthorityProviderOperation -> RequestDigest
authorityProviderOperationDigest operation = case operation of
  AuthorityProviderPending digest _ -> digest
  AuthorityProviderCompleted digest _ _ -> digest

authorityProviderOperationIntent :: AuthorityProviderOperation -> ProviderIntent
authorityProviderOperationIntent operation = case operation of
  AuthorityProviderPending _ intent -> intent
  AuthorityProviderCompleted _ intent _ -> intent

-- | The one retained authority object.  The epoch-binding map has exactly the
-- same key set as the submission ledger; this is checked by the physical codec.
-- @authorityRetainedSubmissionCapacity@ bounds in-flight plus terminal
-- tombstones, while the ledger's own capacity independently bounds in-flight
-- work.
data AuthorityAdmissionAggregate = AuthorityAdmissionAggregate
  { authorityAggregateAdmission :: !AuthorityAdmissionState
  , authorityAggregateMigration :: !AuthorityMigrationMode
  , authorityAggregateSubmissionLedger :: !SubmissionLedger
  , authorityAggregateRetainedCapacity :: !Natural
  , authorityAggregateSubmissionEpochs :: !(Map (ClientId, ClientSequence) AuthorityEpoch)
  , authorityAggregateProviderOperations :: !(Map (ClientId, ClientSequence) AuthorityProviderOperation)
  , authorityAggregateRegisteredClients :: !RegisteredClientTable
  , authorityAggregatePulumiCheckpoints :: !AuthorityPulumiCheckpoints
  , authorityAggregateConfig :: !ConfigState
  , authorityAggregateDecommission :: !AuthorityDecommissionState
  , internalAuthorityAggregateProviderAdmissionEpoch
      :: !ProviderAdmissionEpoch
  }
  deriving stock (Eq, Show, Generic)

-- Keep the original ten-field aggregate readable.  Generic @Serialise@
-- encodes a single-constructor product as a constructor tag followed by its
-- fields, so v6 has list length 11 and v7 has list length 12.  The missing
-- v6 field is never guessed as generation one: it becomes the explicit
-- fail-closed legacy-unbound state.
instance Serialise AuthorityAdmissionAggregate where
  encode aggregate =
    Cbor.encodeListLen 12
      <> Cbor.encodeWord 0
      <> encode (authorityAggregateAdmission aggregate)
      <> encode (authorityAggregateMigration aggregate)
      <> encode (authorityAggregateSubmissionLedger aggregate)
      <> encode (authorityAggregateRetainedCapacity aggregate)
      <> encode (authorityAggregateSubmissionEpochs aggregate)
      <> encode (authorityAggregateProviderOperations aggregate)
      <> encode (authorityAggregateRegisteredClients aggregate)
      <> encode (authorityAggregatePulumiCheckpoints aggregate)
      <> encode (authorityAggregateConfig aggregate)
      <> encode (authorityAggregateDecommission aggregate)
      <> encode (internalAuthorityAggregateProviderAdmissionEpoch aggregate)

  decode = do
    encodedFields <- Cbor.decodeListLen
    unless (encodedFields == 11 || encodedFields == 12) $
      fail "AuthorityAdmissionAggregate: expected v6 or v7 field count"
    constructorTag <- Cbor.decodeWord
    unless (constructorTag == (0 :: Word)) $
      fail "AuthorityAdmissionAggregate: unknown constructor tag"
    admission <- decode
    migration <- decode
    ledger <- decode
    retainedCapacity <- decode
    submissionEpochs <- decode
    providerOperations <- decode
    registeredClients <- decode
    checkpoints <- decode
    config <- decode
    decommission <- decode
    providerAdmissionEpoch <-
      if encodedFields == 11
        then pure initialLegacyProviderAdmissionEpochInternal
        else decode
    pure
      AuthorityAdmissionAggregate
        { authorityAggregateAdmission = admission
        , authorityAggregateMigration = migration
        , authorityAggregateSubmissionLedger = ledger
        , authorityAggregateRetainedCapacity = retainedCapacity
        , authorityAggregateSubmissionEpochs = submissionEpochs
        , authorityAggregateProviderOperations = providerOperations
        , authorityAggregateRegisteredClients = registeredClients
        , authorityAggregatePulumiCheckpoints = checkpoints
        , authorityAggregateConfig = config
        , authorityAggregateDecommission = decommission
        , internalAuthorityAggregateProviderAdmissionEpoch =
            providerAdmissionEpoch
        }

data AuthorityAdmissionConfigurationError
  = AuthorityRetainedCapacityBelowLiveCapacity !Natural !Natural
  | AuthorityRegisteredClientTableInvalid !RegisteredClientTableError
  deriving stock (Eq, Show)

data AuthorityAdmissionInvariantError
  = AuthorityLiveCapacityMismatch !Natural !Natural
  | AuthorityRetainedCapacityMismatch !Natural !Natural
  | AuthorityLivePopulationOverCapacity !Natural !Natural
  | AuthorityRetainedPopulationOverCapacity !Natural !Natural
  | AuthoritySubmissionEpochKeysMismatch
  | AuthorityProviderOperationKeyUnknown !ClientId !ClientSequence
  | AuthorityProviderOperationBindingMismatch !ClientId !ClientSequence
  | AuthorityRegisteredClientInvariant !RegisteredClientTableInvariantError
  | AuthorityRegisteredClientConfigurationMismatch
  | AuthorityRegisteredClientEpochMismatch !ClientId !ClientSequence
  | AuthoritySubmissionCompactionRefused !SubmissionTransitionRefusal
  | AuthorityPulumiCheckpointInvariant
      !AuthorityPulumiCheckpointInvariantError
  | AuthorityConfigInvariant !ConfigStateInvariantError
  | AuthorityDecommissionBindingDigestInvalid
  | AuthorityProviderAdmissionEpochInvalid !ProviderAdmissionEpochError
  | AuthorityProviderOperationReservationMissing !ClientId !ClientSequence
  deriving stock (Eq, Show)

initialCleanInstallAuthority
  :: Natural
  -- ^ maximum in-flight population
  -> Natural
  -- ^ maximum retained submission identities, including tombstones
  -> Either AuthorityAdmissionConfigurationError AuthorityAdmissionAggregate
initialCleanInstallAuthority = initialAuthority AuthorityCleanInstall

initialMigratingAuthority
  :: Natural
  -- ^ maximum in-flight population
  -> Natural
  -- ^ maximum retained submission identities, including tombstones
  -> Either AuthorityAdmissionConfigurationError AuthorityAdmissionAggregate
initialMigratingAuthority =
  initialAuthority (AuthorityMigrationControlled initialImportingMigrationState)

initialCleanInstallAuthorityWithRegisteredClients
  :: Natural
  -> Natural
  -> RegisteredClientTable
  -> Either AuthorityAdmissionConfigurationError AuthorityAdmissionAggregate
initialCleanInstallAuthorityWithRegisteredClients =
  initialAuthorityWithRegisteredClients AuthorityCleanInstall

initialMigratingAuthorityWithRegisteredClients
  :: Natural
  -> Natural
  -> RegisteredClientTable
  -> Either AuthorityAdmissionConfigurationError AuthorityAdmissionAggregate
initialMigratingAuthorityWithRegisteredClients =
  initialAuthorityWithRegisteredClients
    (AuthorityMigrationControlled initialImportingMigrationState)

initialAuthority
  :: AuthorityMigrationMode
  -> Natural
  -> Natural
  -> Either AuthorityAdmissionConfigurationError AuthorityAdmissionAggregate
initialAuthority migration liveCapacity retainedCapacity =
  case mkRegisteredClientTable 1 [] of
    Left err -> Left (AuthorityRegisteredClientTableInvalid err)
    Right registeredClients ->
      initialAuthorityWithRegisteredClients
        migration
        liveCapacity
        retainedCapacity
        registeredClients

initialAuthorityWithRegisteredClients
  :: AuthorityMigrationMode
  -> Natural
  -> Natural
  -> RegisteredClientTable
  -> Either AuthorityAdmissionConfigurationError AuthorityAdmissionAggregate
initialAuthorityWithRegisteredClients migration liveCapacity retainedCapacity registeredClients
  | retainedCapacity < liveCapacity =
      Left (AuthorityRetainedCapacityBelowLiveCapacity liveCapacity retainedCapacity)
  | otherwise =
      Right
        AuthorityAdmissionAggregate
          { authorityAggregateAdmission = initialGenesisState
          , authorityAggregateMigration = migration
          , authorityAggregateSubmissionLedger = emptySubmissionLedger liveCapacity
          , authorityAggregateRetainedCapacity = retainedCapacity
          , authorityAggregateSubmissionEpochs = Map.empty
          , authorityAggregateProviderOperations = Map.empty
          , authorityAggregateRegisteredClients = registeredClients
          , authorityAggregatePulumiCheckpoints =
              initialAuthorityPulumiCheckpoints
          , authorityAggregateConfig = initialConfigState
          , authorityAggregateDecommission = AuthorityServing
          , internalAuthorityAggregateProviderAdmissionEpoch =
              initialLegacyProviderAdmissionEpochInternal
          }

authorityAggregateSubmissionEpoch
  :: ClientId
  -> ClientSequence
  -> AuthorityAdmissionAggregate
  -> Maybe AuthorityEpoch
authorityAggregateSubmissionEpoch client seqNo aggregate =
  Map.lookup (client, seqNo) (authorityAggregateSubmissionEpochs aggregate)

authorityAggregateSubmissionEpochBindings
  :: AuthorityAdmissionAggregate
  -> Map (ClientId, ClientSequence) AuthorityEpoch
authorityAggregateSubmissionEpochBindings = authorityAggregateSubmissionEpochs

authorityAggregateProviderAdmissionEpochView
  :: AuthorityAdmissionAggregate -> ProviderAdmissionEpochView
authorityAggregateProviderAdmissionEpochView =
  providerAdmissionEpochView
    . internalAuthorityAggregateProviderAdmissionEpoch

-- | Validate the retained object against runtime-pinned capacity.  In
-- particular, an epoch entry may neither be absent for a known submission nor
-- survive compaction after the corresponding ledger record is gone.
validateAuthorityAdmissionAggregate
  :: Natural
  -> Natural
  -> AuthorityAdmissionAggregate
  -> Either AuthorityAdmissionInvariantError ()
validateAuthorityAdmissionAggregate expectedLive expectedRetained aggregate
  | observedLiveCapacity /= expectedLive =
      Left (AuthorityLiveCapacityMismatch expectedLive observedLiveCapacity)
  | observedRetainedCapacity /= expectedRetained =
      Left (AuthorityRetainedCapacityMismatch expectedRetained observedRetainedCapacity)
  | livePopulation > observedLiveCapacity =
      Left (AuthorityLivePopulationOverCapacity livePopulation observedLiveCapacity)
  | retainedPopulation > observedRetainedCapacity =
      Left
        ( AuthorityRetainedPopulationOverCapacity
            retainedPopulation
            observedRetainedCapacity
        )
  | ledgerKeys /= epochKeys = Left AuthoritySubmissionEpochKeysMismatch
  | otherwise = do
      either
        (Left . AuthorityRegisteredClientInvariant)
        Right
        (validateRegisteredClientTable ledger (authorityAggregateRegisteredClients aggregate))
      traverse_ validateRegisteredBinding registeredBindings
      either
        (Left . AuthorityPulumiCheckpointInvariant)
        Right
        ( validateAuthorityPulumiCheckpoints
            (authorityAggregatePulumiCheckpoints aggregate)
        )
      either
        (Left . AuthorityConfigInvariant)
        Right
        (validateConfigState (authorityAggregateConfig aggregate))
      validateDecommissionBinding (authorityAggregateDecommission aggregate)
      either
        (Left . AuthorityProviderAdmissionEpochInvalid)
        Right
        ( validateProviderAdmissionEpochInternal
            (internalAuthorityAggregateProviderAdmissionEpoch aggregate)
        )
      traverse_ validateProviderOperation (Map.toList (authorityAggregateProviderOperations aggregate))
 where
  ledger = authorityAggregateSubmissionLedger aggregate
  observedLiveCapacity = submissionCapacity ledger
  observedRetainedCapacity = authorityAggregateRetainedCapacity aggregate
  livePopulation = liveSubmissionCount ledger
  retainedPopulation = fromIntegral (Set.size ledgerKeys)
  ledgerKeys = submissionKeySet ledger
  epochKeys = Map.keysSet (authorityAggregateSubmissionEpochs aggregate)
  validateProviderOperation ((client, seqNo), operation) =
    case lookupSubmissionRecord ledger client seqNo of
      Nothing -> Left (AuthorityProviderOperationKeyUnknown client seqNo)
      Just record
        | submissionRecordDigest record /= authorityProviderOperationDigest operation ->
            Left (AuthorityProviderOperationBindingMismatch client seqNo)
        | Map.notMember (client, seqNo) reservationKeys ->
            Left (AuthorityProviderOperationReservationMissing client seqNo)
        | otherwise -> Right ()
  registeredBindings =
    registeredClientReservationBindings
      (authorityAggregateRegisteredClients aggregate)
  reservationKeys =
    Map.fromList
      [ ((client, seqNo), submissionKey)
      | (submissionKey, client, seqNo, _, _) <-
          registeredClientReservationEntries
            (authorityAggregateRegisteredClients aggregate)
      ]
  validateRegisteredBinding (client, seqNo, _, registeredEpoch) =
    case submissionStatus client seqNo ledger of
      StatusExpired -> Right ()
      _ ->
        if authorityAggregateSubmissionEpoch client seqNo aggregate == Just registeredEpoch
          then Right ()
          else Left (AuthorityRegisteredClientEpochMismatch client seqNo)
  validateDecommissionBinding decommissionState = case decommissionState of
    AuthorityServing -> Right ()
    AuthorityDecommissionFrozen -> Right ()
    AuthorityPermanentlyStopped manifestDigest receiptDigest
      | validDigest manifestDigest && validDigest receiptDigest -> Right ()
      | otherwise -> Left AuthorityDecommissionBindingDigestInvalid
  validDigest (FrameDigest bytes) = ByteString.length bytes == 32

validateAuthorityAdmissionAggregateWithRegisteredClients
  :: Natural
  -> Natural
  -> RegisteredClientTable
  -> AuthorityAdmissionAggregate
  -> Either AuthorityAdmissionInvariantError ()
validateAuthorityAdmissionAggregateWithRegisteredClients
  expectedLive
  expectedRetained
  expectedRegisteredClients
  aggregate = do
    validateAuthorityAdmissionAggregate expectedLive expectedRetained aggregate
    if registeredClientTableConfigurationMatches
      expectedRegisteredClients
      (authorityAggregateRegisteredClients aggregate)
      then Right ()
      else Left AuthorityRegisteredClientConfigurationMismatch

submissionKeySet :: SubmissionLedger -> Set.Set (ClientId, ClientSequence)
submissionKeySet ledger =
  Set.fromList
    [ (client, seqNo)
    | (client, submissions) <- Map.toList (submissionClients ledger)
    , seqNo <- Map.keys (clientRecords submissions)
    ]

data AuthoritySubmissionGateRefusal
  = AuthorityGenesisFrozen
  | AuthorityGenesisEstablishing
  | AuthorityBackupRepairFrozen
  | AuthorityDecommissionAdmissionFrozen
  | AuthorityDecommissionPermanentlyStopped
  | AuthorityLegacyWriterActive
  | AuthorityMigrationWritersQuiesced
  | AuthorityProviderAdmissionCascadeFrozen
  | AuthorityProviderAdmissionCredentialRevoked
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The epoch that may admit a fresh operation.  It comes only from the
-- retained genesis/repair state.  Migration is a writer gate, never a second
-- epoch source.
activeAuthorityEpoch
  :: AuthorityAdmissionAggregate
  -> Either AuthoritySubmissionGateRefusal AuthorityEpoch
activeAuthorityEpoch aggregate =
  case authorityAggregateDecommission aggregate of
    AuthorityDecommissionFrozen -> Left AuthorityDecommissionAdmissionFrozen
    AuthorityPermanentlyStopped _ _ -> Left AuthorityDecommissionPermanentlyStopped
    AuthorityServing ->
      case authorityAggregateAdmission aggregate of
        GenesisFrozen -> Left AuthorityGenesisFrozen
        EstablishingBackup _ -> Left AuthorityGenesisEstablishing
        BackupRepairFrozen _ _ -> Left AuthorityBackupRepairFrozen
        BackupEstablished epoch _ _ -> case authorityAggregateMigration aggregate of
          AuthorityCleanInstall -> Right epoch
          AuthorityMigrationControlled migration ->
            case migrationAuthorityStatus migration of
              MigrationLegacyWriterActive -> Left AuthorityLegacyWriterActive
              MigrationWritersQuiesced -> Left AuthorityMigrationWritersQuiesced
              MigrationReplacementWriterActive _ -> Right epoch

-- | A config proposal shares the exact admission gate and retained revision
-- with operation submission.  The epoch is intentionally not copied into the
-- config projection: proving that one exists is the atomic authorization to
-- evolve the generation.
data AuthorityConfigProposalDecision
  = AuthorityConfigProposalRefusedByGate !AuthoritySubmissionGateRefusal
  | AuthorityConfigProposalDecided !ConfigProposeDecision
  deriving stock (Eq, Show)

decideAuthorityConfigProposal
  :: SchemaValidity
  -> AuthorityAdmissionAggregate
  -> ConfigProposal
  -> AuthorityConfigProposalDecision
decideAuthorityConfigProposal validity aggregate proposal =
  case activeAuthorityEpoch aggregate of
    Left refusal -> AuthorityConfigProposalRefusedByGate refusal
    Right _ ->
      AuthorityConfigProposalDecided
        (fst (stepConfigPropose validity (authorityAggregateConfig aggregate) proposal))

stepAuthorityConfigProposal
  :: SchemaValidity
  -> AuthorityAdmissionAggregate
  -> ConfigProposal
  -> (AuthorityConfigProposalDecision, AuthorityAdmissionAggregate)
stepAuthorityConfigProposal validity aggregate proposal =
  case activeAuthorityEpoch aggregate of
    Left refusal -> (AuthorityConfigProposalRefusedByGate refusal, aggregate)
    Right _ ->
      let (decision, nextConfig) =
            stepConfigPropose validity (authorityAggregateConfig aggregate) proposal
       in ( AuthorityConfigProposalDecided decision
          , aggregate {authorityAggregateConfig = nextConfig}
          )

-- | Atomically close normal operation admission in the retained aggregate.
-- Exact replay is a no-op; a permanently stopped Authority never reopens.
freezeAuthorityForDecommission
  :: AuthorityAdmissionAggregate
  -> (AuthorityDecommissionDecision, AuthorityAdmissionAggregate)
freezeAuthorityForDecommission aggregate =
  case authorityAggregateDecommission aggregate of
    AuthorityServing ->
      ( AuthorityDecommissionFreezeApplied
      , aggregate {authorityAggregateDecommission = AuthorityDecommissionFrozen}
      )
    AuthorityDecommissionFrozen ->
      (AuthorityDecommissionFreezeAlreadyApplied, aggregate)
    AuthorityPermanentlyStopped _ _ ->
      (AuthorityDecommissionFreezeRefusedAlreadyStopped, aggregate)

-- | Cross the point of no return only from the frozen state, binding the exact
-- signed manifest digest and external-receipt acknowledgement digest.  The
-- same pair is response-loss idempotent; any divergent pair is refused.
permanentlyStopAuthorityForDecommission
  :: FrameDigest
  -> FrameDigest
  -> AuthorityAdmissionAggregate
  -> (AuthorityDecommissionDecision, AuthorityAdmissionAggregate)
permanentlyStopAuthorityForDecommission manifestDigest receiptDigest aggregate =
  case authorityAggregateDecommission aggregate of
    AuthorityServing ->
      (AuthorityDecommissionStopRefusedBeforeFreeze, aggregate)
    AuthorityDecommissionFrozen ->
      ( AuthorityDecommissionStopApplied
      , aggregate
          { authorityAggregateDecommission =
              AuthorityPermanentlyStopped manifestDigest receiptDigest
          }
      )
    AuthorityPermanentlyStopped committedManifest committedReceipt
      | committedManifest == manifestDigest && committedReceipt == receiptDigest ->
          (AuthorityDecommissionStopAlreadyApplied, aggregate)
      | otherwise ->
          ( AuthorityDecommissionStopRefusedBindingConflict
              committedManifest
              committedReceipt
              manifestDigest
              receiptDigest
          , aggregate
          )

data AuthorityAdmissionCommand
  = ApplyAuthorityGenesis !AuthorityGenesisCommand
  | ApplyAuthorityBackupRepair !BackupRepairCommand
  | BeginAuthorityMigration
  | ApplyAuthorityMigration !MigrationCommand
  | ApplyAuthorityMigrationImport !MigrationImportCommand
  | ApplyAuthorityForwardMigration !MigrationForwardCommand
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityAdmissionCommandRefusal
  = AuthorityMigrationAlreadyStarted
  | AuthorityMigrationNotStarted
  | AuthorityMigrationBeforeGenesis
  | AuthorityMigrationDuringBackupRepair
  | AuthorityMigrationEpochRegressed !AuthorityEpoch !AuthorityEpoch
  deriving stock (Eq, Show)

data AuthorityAdmissionDecision
  = AuthorityGenesisDecided !GenesisDecision
  | AuthorityBackupRepairDecided !BackupRepairDecision
  | AuthorityMigrationStarted
  | AuthorityMigrationDecided !MigrationDecision
  | AuthorityMigrationImportDecided !MigrationImportDecision
  | AuthorityForwardMigrationDecided !MigrationForwardDecision
  | AuthorityAdmissionCommandRefused !AuthorityAdmissionCommandRefusal
  deriving stock (Eq, Show)

-- | Apply one control transition to the same object used by submission.  A
-- migration activation advances the retained admission epoch in that same CAS;
-- before activation the migration writer gate remains closed.
stepAuthorityAdmission
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionCommand
  -> (AuthorityAdmissionDecision, AuthorityAdmissionAggregate)
stepAuthorityAdmission aggregate command = case command of
  ApplyAuthorityGenesis genesis ->
    let (decision, nextAdmission) =
          stepGenesis (authorityAggregateAdmission aggregate) genesis
     in ( AuthorityGenesisDecided decision
        , aggregate {authorityAggregateAdmission = nextAdmission}
        )
  ApplyAuthorityBackupRepair repair ->
    let (decision, nextAdmission) =
          stepBackupRepair (authorityAggregateAdmission aggregate) repair
     in ( AuthorityBackupRepairDecided decision
        , aggregate {authorityAggregateAdmission = nextAdmission}
        )
  BeginAuthorityMigration ->
    case authorityAggregateAdmission aggregate of
      GenesisFrozen -> refuse AuthorityMigrationBeforeGenesis
      EstablishingBackup _ -> refuse AuthorityMigrationBeforeGenesis
      BackupRepairFrozen _ _ -> refuse AuthorityMigrationDuringBackupRepair
      BackupEstablished {} -> case authorityAggregateMigration aggregate of
        AuthorityCleanInstall ->
          ( AuthorityMigrationStarted
          , aggregate
              { authorityAggregateMigration =
                  AuthorityMigrationControlled initialImportingMigrationState
              }
          )
        AuthorityMigrationControlled _ -> refuse AuthorityMigrationAlreadyStarted
  ApplyAuthorityMigration migrationCommand ->
    applyMigrationTransition
      aggregate
      ( \state ->
          let (next, decision) = stepMigration state migrationCommand
           in (AuthorityMigrationDecided decision, next)
      )
  ApplyAuthorityMigrationImport migrationCommand ->
    applyMigrationTransition
      aggregate
      ( \state ->
          let (next, decision) = stepMigrationImport state migrationCommand
           in (AuthorityMigrationImportDecided decision, next)
      )
  ApplyAuthorityForwardMigration migrationCommand ->
    applyMigrationTransition
      aggregate
      ( \state ->
          let (next, decision) = stepForwardMigration state migrationCommand
           in (AuthorityForwardMigrationDecided decision, next)
      )
 where
  refuse refusal = (AuthorityAdmissionCommandRefused refusal, aggregate)

applyMigrationTransition
  :: AuthorityAdmissionAggregate
  -> (MigrationState -> (AuthorityAdmissionDecision, MigrationState))
  -> (AuthorityAdmissionDecision, AuthorityAdmissionAggregate)
applyMigrationTransition aggregate transition =
  case authorityAggregateAdmission aggregate of
    GenesisFrozen -> refuse AuthorityMigrationBeforeGenesis
    EstablishingBackup _ -> refuse AuthorityMigrationBeforeGenesis
    BackupRepairFrozen _ _ -> refuse AuthorityMigrationDuringBackupRepair
    BackupEstablished currentEpoch targetReceipt backupReceipt ->
      case authorityAggregateMigration aggregate of
        AuthorityCleanInstall -> refuse AuthorityMigrationNotStarted
        AuthorityMigrationControlled currentMigration ->
          let (decision, nextMigration) = transition currentMigration
           in case activatedAuthorityEpoch currentMigration nextMigration of
                Just nextEpoch
                  | nextEpoch < currentEpoch ->
                      refuse (AuthorityMigrationEpochRegressed currentEpoch nextEpoch)
                  | otherwise ->
                      ( decision
                      , aggregate
                          { authorityAggregateAdmission =
                              BackupEstablished nextEpoch targetReceipt backupReceipt
                          , authorityAggregateMigration =
                              AuthorityMigrationControlled nextMigration
                          }
                      )
                Nothing ->
                  ( decision
                  , aggregate
                      { authorityAggregateMigration =
                          AuthorityMigrationControlled nextMigration
                      }
                  )
 where
  refuse refusal = (AuthorityAdmissionCommandRefused refusal, aggregate)

activatedAuthorityEpoch :: MigrationState -> MigrationState -> Maybe AuthorityEpoch
activatedAuthorityEpoch current next =
  case (migrationAuthorityStatus current, migrationAuthorityStatus next) of
    (MigrationReplacementWriterActive _, MigrationReplacementWriterActive _) -> Nothing
    (_, MigrationReplacementWriterActive epoch) ->
      authorityEpochFromValue (fromIntegral (migrationEpochValue epoch))
    (_, MigrationLegacyWriterActive) -> Nothing
    (_, MigrationWritersQuiesced) -> Nothing

data AuthoritySubmissionDecision
  = AuthoritySubmissionDecided !SubmitDecision
  | AuthoritySubmissionRefusedByGate !AuthoritySubmissionGateRefusal
  | AuthoritySubmissionRefusedRetainedCapacity
  deriving stock (Eq, Show)

-- | Production submission outcome.  The caller identity and key generation
-- come from the verified transport slot; the client sequence is allocated by
-- the retained registry in the same CAS update as the submission ledger.
data AuthorityRegisteredSubmissionDecision
  = AuthorityRegisteredSubmissionDecided !RegisteredSubmissionDecision
  | AuthorityRegisteredSubmissionRefusedByGate !AuthoritySubmissionGateRefusal
  | AuthorityRegisteredSubmissionRefusedRetainedCapacity
  deriving stock (Eq, Show)

decideRegisteredAuthoritySubmission
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> Either AuthorityAdmissionInvariantError AuthorityRegisteredSubmissionDecision
decideRegisteredAuthoritySubmission aggregate caller generation submissionKey digest =
  fst
    <$> prepareRegisteredAuthoritySubmission
      aggregate
      caller
      generation
      submissionKey
      digest

decideRegisteredAuthoritySubmissionUncompacted
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> Either AuthorityAdmissionInvariantError AuthorityRegisteredSubmissionDecision
decideRegisteredAuthoritySubmissionUncompacted aggregate caller generation submissionKey digest = do
  validateAuthorityAdmissionAggregate liveCapacity retainedCapacity aggregate
  case inspectRegisteredSubmission
    ledger
    registeredClients
    caller
    generation
    submissionKey
    digest of
    RegisteredSubmissionKnown decision ->
      pure (AuthorityRegisteredSubmissionDecided decision)
    RegisteredSubmissionFresh
      | retainedSubmissionCount ledger >= retainedCapacity ->
          pure AuthorityRegisteredSubmissionRefusedRetainedCapacity
      | otherwise -> case activeAuthorityEpoch aggregate of
          Left refusal -> pure (AuthorityRegisteredSubmissionRefusedByGate refusal)
          Right epoch ->
            pure
              ( AuthorityRegisteredSubmissionDecided
                  registeredDecision
              )
           where
            (registeredDecision, _, _) =
              reserveRegisteredSubmission
                epoch
                ledger
                registeredClients
                caller
                generation
                submissionKey
                digest
 where
  ledger = authorityAggregateSubmissionLedger aggregate
  registeredClients = authorityAggregateRegisteredClients aggregate
  liveCapacity = submissionCapacity ledger
  retainedCapacity = authorityAggregateRetainedCapacity aggregate

stepRegisteredAuthoritySubmission
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> Either
       AuthorityAdmissionInvariantError
       (AuthorityRegisteredSubmissionDecision, AuthorityAdmissionAggregate)
stepRegisteredAuthoritySubmission aggregate caller generation submissionKey digest = do
  (decision, prepared) <-
    prepareRegisteredAuthoritySubmission
      aggregate
      caller
      generation
      submissionKey
      digest
  case decision of
    AuthorityRegisteredSubmissionDecided
      accepted@(RegisteredSubmissionAccepted operationId) ->
        let (reserved, nextLedger, nextRegisteredClients) =
              reserveRegisteredSubmission
                (operationIdEpoch operationId)
                (authorityAggregateSubmissionLedger prepared)
                (authorityAggregateRegisteredClients prepared)
                caller
                generation
                submissionKey
                digest
            next =
              prepared
                { authorityAggregateSubmissionLedger = nextLedger
                , authorityAggregateSubmissionEpochs =
                    Map.insert
                      (operationIdClient operationId, operationIdSequence operationId)
                      (operationIdEpoch operationId)
                      (authorityAggregateSubmissionEpochs prepared)
                , authorityAggregateRegisteredClients = nextRegisteredClients
                }
         in if reserved == accepted
              then Right (AuthorityRegisteredSubmissionDecided accepted, next)
              else
                Right
                  ( AuthorityRegisteredSubmissionDecided
                      RegisteredSubmissionRefusedLedgerDiverged
                  , aggregate
                  )
    _ -> Right (decision, aggregate)

prepareRegisteredAuthoritySubmission
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> Either
       AuthorityAdmissionInvariantError
       (AuthorityRegisteredSubmissionDecision, AuthorityAdmissionAggregate)
prepareRegisteredAuthoritySubmission aggregate caller generation submissionKey digest = do
  decision <-
    decideRegisteredAuthoritySubmissionUncompacted
      aggregate
      caller
      generation
      submissionKey
      digest
  case decision of
    AuthorityRegisteredSubmissionRefusedRetainedCapacity -> do
      compacted <- compactOneTerminalSubmission aggregate
      case compacted of
        Nothing -> pure (decision, aggregate)
        Just next -> prepareRegisteredAuthoritySubmission next caller generation submissionKey digest
    _ -> pure (decision, aggregate)

observeRegisteredAuthoritySubmission
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> Either AuthorityAdmissionInvariantError RegisteredSubmissionObservation
observeRegisteredAuthoritySubmission aggregate caller generation submissionKey = do
  let ledger = authorityAggregateSubmissionLedger aggregate
  validateAuthorityAdmissionAggregate
    (submissionCapacity ledger)
    (authorityAggregateRetainedCapacity aggregate)
    aggregate
  pure
    ( observeRegisteredSubmission
        ledger
        (authorityAggregateRegisteredClients aggregate)
        caller
        generation
        submissionKey
    )

data AuthorityProviderSubmissionDecision
  = AuthorityProviderSubmissionAccepted !OperationId
  | AuthorityProviderSubmissionDuplicatePending !OperationId
  | AuthorityProviderSubmissionDuplicateCompleted !OperationId !Text
  | AuthorityProviderSubmissionRefused !AuthorityRegisteredSubmissionDecision
  deriving stock (Eq, Show)

data AuthorityProviderSettlementDecision
  = AuthorityProviderSettlementCompleted
  | AuthorityProviderSettlementAlreadyCompleted !Text
  | AuthorityProviderSettlementRefused !Text
  deriving stock (Eq, Show)

-- | Reserve a registered submission and retain its exact Provider intent in
-- the same aggregate transition.  A duplicate is accepted only when the
-- retained intent and digest are byte-for-byte equal to the retry.
stepRegisteredProviderSubmission
  :: AuthorityAdmissionAggregate
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> ProviderIntent
  -> Either
       AuthorityAdmissionInvariantError
       (AuthorityProviderSubmissionDecision, AuthorityAdmissionAggregate)
stepRegisteredProviderSubmission aggregate caller generation submissionKey digest intent = do
  validateCurrentAggregate aggregate
  case inspectRegisteredSubmission
    (authorityAggregateSubmissionLedger aggregate)
    (authorityAggregateRegisteredClients aggregate)
    caller
    generation
    submissionKey
    digest of
    RegisteredSubmissionFresh
      | Just refusal <-
          providerAdmissionFreshSubmissionRefusalInternal
            (internalAuthorityAggregateProviderAdmissionEpoch aggregate) ->
          pure
            ( AuthorityProviderSubmissionRefused
                ( AuthorityRegisteredSubmissionRefusedByGate
                    (providerAdmissionGateRefusal refusal)
                )
            , aggregate
            )
    _ -> submitOrReplay
 where
  submitOrReplay = do
    (decision, submitted) <-
      stepRegisteredAuthoritySubmission
        aggregate
        caller
        generation
        submissionKey
        digest
    case decision of
      AuthorityRegisteredSubmissionDecided (RegisteredSubmissionAccepted operation) -> do
        let key = providerOperationKey operation
            next =
              submitted
                { authorityAggregateProviderOperations =
                    Map.insert
                      key
                      (AuthorityProviderPending digest intent)
                      (authorityAggregateProviderOperations submitted)
                }
        validateCurrentAggregate next
        pure (AuthorityProviderSubmissionAccepted operation, next)
      AuthorityRegisteredSubmissionDecided (RegisteredSubmissionDuplicate operation) ->
        confirmDuplicate operation submitted
      _ -> pure (AuthorityProviderSubmissionRefused decision, submitted)

  confirmDuplicate operation submitted =
    case Map.lookup (providerOperationKey operation) (authorityAggregateProviderOperations submitted) of
      Just retained
        | authorityProviderOperationDigest retained == digest
            && authorityProviderOperationIntent retained == intent ->
            pure
              ( case retained of
                  AuthorityProviderPending {} ->
                    AuthorityProviderSubmissionDuplicatePending operation
                  AuthorityProviderCompleted _ _ evidence ->
                    AuthorityProviderSubmissionDuplicateCompleted operation evidence
              , submitted
              )
      _ ->
        Left
          ( AuthorityProviderOperationBindingMismatch
              (operationIdClient operation)
              (operationIdSequence operation)
          )

providerAdmissionGateRefusal
  :: ProviderAdmissionFreshSubmissionRefusal
  -> AuthoritySubmissionGateRefusal
providerAdmissionGateRefusal refusal = case refusal of
  ProviderAdmissionFreshSubmissionCascadeAuditFrozen ->
    AuthorityProviderAdmissionCascadeFrozen
  ProviderAdmissionFreshSubmissionCredentialRevoked ->
    AuthorityProviderAdmissionCredentialRevoked

-- | Settle the exact retained Provider operation and its submission ledger in
-- one transition.  The completed evidence is immutable; a divergent replay is
-- refused without rewriting the first durable result.
stepRegisteredProviderSettlement
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> ProviderIntent
  -> Text
  -> AuthorityAdmissionAggregate
  -> Either
       AuthorityAdmissionInvariantError
       (AuthorityProviderSettlementDecision, AuthorityAdmissionAggregate)
stepRegisteredProviderSettlement caller generation operation intent evidence aggregate = do
  validateCurrentAggregate aggregate
  if registeredClientIdForCaller caller generation (authorityAggregateRegisteredClients aggregate)
    == Just (operationIdClient operation)
    then Right ()
    else pureBindingFailure
  let key = providerOperationKey operation
  case Map.lookup key (authorityAggregateProviderOperations aggregate) of
    Nothing -> pure (AuthorityProviderSettlementRefused "provider operation is not retained", aggregate)
    Just retained
      | authorityProviderOperationDigest retained /= operationIdDigest operation
          || authorityProviderOperationIntent retained /= intent ->
          pure (AuthorityProviderSettlementRefused "provider operation binding mismatch", aggregate)
      | authorityAggregateSubmissionEpoch
          (operationIdClient operation)
          (operationIdSequence operation)
          aggregate
          /= Just (operationIdEpoch operation) ->
          pure (AuthorityProviderSettlementRefused "provider operation epoch mismatch", aggregate)
      | otherwise -> settle key retained
 where
  pureBindingFailure =
    Left
      ( AuthorityProviderOperationBindingMismatch
          (operationIdClient operation)
          (operationIdSequence operation)
      )

  settle _ (AuthorityProviderCompleted _ _ existing)
    | existing == evidence =
        pure (AuthorityProviderSettlementAlreadyCompleted existing, aggregate)
    | otherwise =
        pure
          ( AuthorityProviderSettlementRefused "provider completion evidence mismatch"
          , aggregate
          )
  settle key (AuthorityProviderPending digest retainedIntent)
    | not (validProviderEvidence evidence) =
        pure (AuthorityProviderSettlementRefused "provider completion evidence is invalid", aggregate)
    | otherwise =
        case completeSubmission
          (operationIdClient operation)
          (operationIdSequence operation)
          (authorityAggregateSubmissionLedger aggregate) of
          Left SubmissionCompleteAfterCancel ->
            pure (AuthorityProviderSettlementRefused "provider submission was cancelled", aggregate)
          Left _ ->
            pure (AuthorityProviderSettlementRefused "provider submission is unavailable", aggregate)
          Right ledger -> do
            let next =
                  aggregate
                    { authorityAggregateSubmissionLedger = ledger
                    , authorityAggregateProviderOperations =
                        Map.insert
                          key
                          (AuthorityProviderCompleted digest retainedIntent evidence)
                          (authorityAggregateProviderOperations aggregate)
                    }
            validateCurrentAggregate next
            pure (AuthorityProviderSettlementCompleted, next)

providerOperationKey :: OperationId -> (ClientId, ClientSequence)
providerOperationKey operation =
  (operationIdClient operation, operationIdSequence operation)

validProviderEvidence :: Text -> Bool
validProviderEvidence evidence =
  not (Text.null evidence)
    && Text.length evidence <= 4096
    && not (Text.any (\character -> character <= '\x1f' || character == '\x7f') evidence)

-- | Derive the sole checkpoint token for an admitted operation identity.  The
-- canonical tuple is hashed so no caller-controlled client or request text is
-- exposed on the checkpoint route and one operation cannot mint multiple
-- independent checkpoint capabilities.
authorityCheckpointOperationRef
  :: OperationId
  -> Either PulumiCheckpointOperationRefError PulumiCheckpointOperationRef
authorityCheckpointOperationRef operation =
  mkPulumiCheckpointOperationRef
    ( Text.pack "authority-operation-v1-"
        <> sha256Hex
          ( LazyByteString.toStrict
              ( serialise
                  ( 1 :: Word
                  , authorityEpochValue (operationIdEpoch operation)
                  , clientText (operationIdClient operation)
                  , sequenceValue (operationIdSequence operation)
                  , requestDigestText (operationIdDigest operation)
                  )
              )
          )
    )
 where
  clientText (ClientId value) = value
  sequenceValue (ClientSequence value) = value
  requestDigestText (RequestDigest value) = value

stepAuthorityCheckpointPermit
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> RegisteredPulumiCheckpoint
  -> CheckpointOperationKind
  -> Maybe PulumiCheckpointDigest
  -> AuthorityAdmissionAggregate
  -> Either
       AuthorityAdmissionInvariantError
       (CheckpointPermitDecision, AuthorityAdmissionAggregate)
stepAuthorityCheckpointPermit caller generation operationId registered kind expected aggregate = do
  validateCurrentAggregate aggregate
  case admittedOperationRecord caller generation operationId aggregate of
    Left refusal -> pure (refusal, aggregate)
    Right record -> case authorityCheckpointOperationRef operationId of
      Left _ -> pure (CheckpointPermitRefusedSubmissionBinding, aggregate)
      Right operation -> registerWithCapacityRecovery record operation aggregate
 where
  registerWithCapacityRecovery record operation current = do
    (decision, checkpoints) <-
      mapLeftInvariant
        ( registerCheckpointOperationPermit
            operation
            registered
            kind
            expected
            (authorityAggregatePulumiCheckpoints current)
        )
    case record of
      SubmissionInFlight _
        | decision == CheckpointPermitRefusedCapacity -> do
            compacted <- compactOneTerminalSubmission current
            case compacted of
              Nothing -> pure (decision, aggregate)
              Just next -> registerWithCapacityRecovery record operation next
        | otherwise -> validateCheckpointUpdate current decision checkpoints
      SubmissionSettled _ OperationCompletedOutcome
        | decision == CheckpointPermitAlreadyRegistered ->
            validateCheckpointUpdate current decision checkpoints
        | otherwise ->
            pure (CheckpointPermitRefusedSubmissionNotInFlight, aggregate)
      SubmissionSettled _ OperationCancelledOutcome ->
        pure (CheckpointPermitRefusedSubmissionNotInFlight, aggregate)

admittedOperationRecord
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> AuthorityAdmissionAggregate
  -> Either CheckpointPermitDecision SubmissionRecord
admittedOperationRecord caller generation operation aggregate
  | registeredClientIdForCaller
      caller
      generation
      (authorityAggregateRegisteredClients aggregate)
      /= Just (operationIdClient operation) =
      Left CheckpointPermitRefusedSubmissionBinding
  | otherwise = case lookupSubmissionRecord
      (authorityAggregateSubmissionLedger aggregate)
      (operationIdClient operation)
      (operationIdSequence operation) of
      Nothing -> Left CheckpointPermitRefusedSubmissionUnknown
      Just record
        | submissionRecordDigest record /= operationIdDigest operation ->
            Left CheckpointPermitRefusedSubmissionBinding
        | authorityAggregateSubmissionEpoch
            (operationIdClient operation)
            (operationIdSequence operation)
            aggregate
            /= Just (operationIdEpoch operation) ->
            Left CheckpointPermitRefusedSubmissionBinding
        | otherwise -> Right record

authorityCheckpointOperationStatus
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> AuthorityAdmissionAggregate
  -> Either CheckpointPermitDecision SubmissionStatus
authorityCheckpointOperationStatus caller generation operation aggregate =
  case admittedOperationRecord caller generation operation aggregate of
    Left refusal -> Left refusal
    Right record -> Right $ case record of
      SubmissionInFlight _ -> StatusInFlight
      SubmissionSettled _ outcome -> StatusSettled outcome

stepAuthorityCheckpointPublication
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> AuthorityAdmissionAggregate
  -> Either
       AuthorityAdmissionInvariantError
       (CheckpointMutationDecision, AuthorityAdmissionAggregate)
stepAuthorityCheckpointPublication caller generation operationId registered reference aggregate = do
  validateCurrentAggregate aggregate
  case admittedOperationRecord caller generation operationId aggregate of
    Left CheckpointPermitRefusedSubmissionUnknown ->
      pure (CheckpointMutationRefusedUnknownOperation, aggregate)
    Left _ -> pure (CheckpointMutationRefusedBinding, aggregate)
    Right record -> case authorityCheckpointOperationRef operationId of
      Left _ -> pure (CheckpointMutationRefusedBinding, aggregate)
      Right operation -> do
        (decision, checkpoints) <-
          mapLeftInvariant
            ( applyCheckpointPublication
                operation
                registered
                reference
                (authorityAggregatePulumiCheckpoints aggregate)
            )
        settleCheckpointMutation operationId record decision checkpoints aggregate

stepAuthorityCheckpointRestore
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> VerifiedPulumiCheckpointRef
  -> AuthorityAdmissionAggregate
  -> Either
       AuthorityAdmissionInvariantError
       (CheckpointMutationDecision, AuthorityAdmissionAggregate)
stepAuthorityCheckpointRestore
  caller
  generation
  operationId
  registered
  predecessor
  current
  aggregate = do
    validateCurrentAggregate aggregate
    case admittedOperationRecord caller generation operationId aggregate of
      Left CheckpointPermitRefusedSubmissionUnknown ->
        pure (CheckpointMutationRefusedUnknownOperation, aggregate)
      Left _ -> pure (CheckpointMutationRefusedBinding, aggregate)
      Right record -> case authorityCheckpointOperationRef operationId of
        Left _ -> pure (CheckpointMutationRefusedBinding, aggregate)
        Right operation -> do
          (decision, checkpoints) <-
            mapLeftInvariant
              ( applyCheckpointRestore
                  operation
                  registered
                  predecessor
                  current
                  (authorityAggregatePulumiCheckpoints aggregate)
              )
          settleCheckpointMutation operationId record decision checkpoints aggregate

stepAuthorityCheckpointRetirement
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> OperationId
  -> RegisteredPulumiCheckpoint
  -> AuthorityAdmissionAggregate
  -> Either
       AuthorityAdmissionInvariantError
       (CheckpointMutationDecision, AuthorityAdmissionAggregate)
stepAuthorityCheckpointRetirement caller generation operationId registered aggregate = do
  validateCurrentAggregate aggregate
  case admittedOperationRecord caller generation operationId aggregate of
    Left CheckpointPermitRefusedSubmissionUnknown ->
      pure (CheckpointMutationRefusedUnknownOperation, aggregate)
    Left _ -> pure (CheckpointMutationRefusedBinding, aggregate)
    Right record -> case authorityCheckpointOperationRef operationId of
      Left _ -> pure (CheckpointMutationRefusedBinding, aggregate)
      Right operation -> do
        (decision, checkpoints) <-
          mapLeftInvariant
            ( applyCheckpointRetirement
                operation
                registered
                (authorityAggregatePulumiCheckpoints aggregate)
            )
        settleCheckpointMutation operationId record decision checkpoints aggregate

settleCheckpointMutation
  :: OperationId
  -> SubmissionRecord
  -> CheckpointMutationDecision
  -> AuthorityPulumiCheckpoints
  -> AuthorityAdmissionAggregate
  -> Either
       AuthorityAdmissionInvariantError
       (CheckpointMutationDecision, AuthorityAdmissionAggregate)
settleCheckpointMutation operation record decision checkpoints aggregate =
  case decision of
    CheckpointMutationApplied -> complete checkpoints
    CheckpointMutationAlreadyApplied -> complete checkpoints
    _ -> validateCheckpointUpdate aggregate decision checkpoints
 where
  complete nextCheckpoints = case record of
    SubmissionSettled _ OperationCancelledOutcome ->
      pure (CheckpointMutationRefusedBinding, aggregate)
    _ ->
      case completeSubmission
        (operationIdClient operation)
        (operationIdSequence operation)
        (authorityAggregateSubmissionLedger aggregate) of
        Left refusal ->
          pure (submissionCompletionRefusal refusal, aggregate)
        Right nextLedger -> do
          let next =
                aggregate
                  { authorityAggregatePulumiCheckpoints = nextCheckpoints
                  , authorityAggregateSubmissionLedger = nextLedger
                  }
          validateCurrentAggregate next
          pure (decision, next)

submissionCompletionRefusal
  :: SubmissionTransitionRefusal -> CheckpointMutationDecision
submissionCompletionRefusal _ = CheckpointMutationRefusedBinding

-- | Compact one deterministic terminal submission and its terminal checkpoint
-- permit.  The per-client floor preserves expiry; the registered reservation
-- remains as the bounded idempotency-key cursor, so a compacted key can never
-- be allocated a fresh mutation identity.
compactOneTerminalSubmission
  :: AuthorityAdmissionAggregate
  -> Either AuthorityAdmissionInvariantError (Maybe AuthorityAdmissionAggregate)
compactOneTerminalSubmission aggregate =
  tryCandidates (terminalHeadCandidates (authorityAggregateSubmissionLedger aggregate))
 where
  tryCandidates [] = pure Nothing
  tryCandidates ((client, seqNo, digest) : rest) =
    case authorityAggregateSubmissionEpoch client seqNo aggregate of
      Nothing -> Left AuthoritySubmissionEpochKeysMismatch
      Just epoch ->
        let operationId = OperationId epoch client seqNo digest
         in case authorityCheckpointOperationRef operationId of
              Left _ -> tryCandidates rest
              Right operation -> do
                (canCompact, checkpoints) <-
                  mapLeftInvariant
                    ( compactTerminalCheckpointOperation
                        operation
                        (authorityAggregatePulumiCheckpoints aggregate)
                    )
                if not canCompact
                  then tryCandidates rest
                  else do
                    nextLedger <-
                      mapLeftSubmission
                        ( compactClientTerminalsBelow
                            client
                            seqNo
                            (authorityAggregateSubmissionLedger aggregate)
                        )
                    let next =
                          aggregate
                            { authorityAggregateSubmissionLedger = nextLedger
                            , authorityAggregateSubmissionEpochs =
                                Map.delete
                                  (client, seqNo)
                                  (authorityAggregateSubmissionEpochs aggregate)
                            , authorityAggregateProviderOperations =
                                Map.delete
                                  (client, seqNo)
                                  (authorityAggregateProviderOperations aggregate)
                            , authorityAggregatePulumiCheckpoints = checkpoints
                            }
                    validateCurrentAggregate next
                    pure (Just next)

terminalHeadCandidates
  :: SubmissionLedger -> [(ClientId, ClientSequence, RequestDigest)]
terminalHeadCandidates ledger =
  [ (client, seqNo, digest)
  | (client, submissions) <- Map.toAscList (submissionClients ledger)
  , Just (seqNo, SubmissionSettled digest _) <-
      [Map.lookupGT (clientSequenceFloor submissions) (clientRecords submissions)]
  ]

mapLeftSubmission
  :: Either SubmissionTransitionRefusal value
  -> Either AuthorityAdmissionInvariantError value
mapLeftSubmission = either (Left . AuthoritySubmissionCompactionRefused) Right

validateCurrentAggregate
  :: AuthorityAdmissionAggregate
  -> Either AuthorityAdmissionInvariantError ()
validateCurrentAggregate aggregate =
  validateAuthorityAdmissionAggregate
    (submissionCapacity (authorityAggregateSubmissionLedger aggregate))
    (authorityAggregateRetainedCapacity aggregate)
    aggregate

mapLeftInvariant
  :: Either AuthorityPulumiCheckpointInvariantError value
  -> Either AuthorityAdmissionInvariantError value
mapLeftInvariant = either (Left . AuthorityPulumiCheckpointInvariant) Right

validateCheckpointUpdate
  :: AuthorityAdmissionAggregate
  -> decision
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityAdmissionInvariantError
       (decision, AuthorityAdmissionAggregate)
validateCheckpointUpdate aggregate decision checkpoints = do
  let next = aggregate {authorityAggregatePulumiCheckpoints = checkpoints}
  validateCurrentAggregate next
  pure (decision, next)

sha256Hex :: ByteString.ByteString -> Text
sha256Hex =
  Text.pack
    . concatMap renderByte
    . ByteString.unpack
    . SHA256.hash
 where
  renderByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | Decide a submission without mutation.  Existing identities are resolved
-- before consulting the current gate: a response-lost acceptance remains
-- recoverable after a subsequent freeze.  Only a genuinely fresh identity needs
-- the current retained admission epoch.
decideAuthoritySubmission
  :: AuthorityAdmissionAggregate
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> Either AuthorityAdmissionInvariantError AuthoritySubmissionDecision
decideAuthoritySubmission aggregate client seqNo digest = do
  validateAuthorityAdmissionAggregate liveCapacity retainedCapacity aggregate
  case lookupSubmissionRecord ledger client seqNo of
    Just record -> do
      boundEpoch <-
        maybe
          (Left AuthoritySubmissionEpochKeysMismatch)
          Right
          (authorityAggregateSubmissionEpoch client seqNo aggregate)
      pure (AuthoritySubmissionDecided (existingDecision boundEpoch record))
    Nothing
      | sequenceExpired ledger client seqNo ->
          pure (AuthoritySubmissionDecided SubmissionRefusedExpired)
      | retainedSubmissionCount ledger >= retainedCapacity ->
          pure AuthoritySubmissionRefusedRetainedCapacity
      | otherwise -> case activeAuthorityEpoch aggregate of
          Left refusal -> pure (AuthoritySubmissionRefusedByGate refusal)
          Right epoch ->
            pure
              ( AuthoritySubmissionDecided
                  (fst (stepSubmit epoch ledger client seqNo digest))
              )
 where
  ledger = authorityAggregateSubmissionLedger aggregate
  liveCapacity = submissionCapacity ledger
  retainedCapacity = authorityAggregateRetainedCapacity aggregate
  existingDecision epoch record =
    let existingDigest = submissionRecordDigest record
        operationId = OperationId epoch client seqNo digest
     in if existingDigest == digest
          then SubmissionDuplicate operationId
          else SubmissionRefusedSequenceReused

stepAuthoritySubmission
  :: AuthorityAdmissionAggregate
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> Either
       AuthorityAdmissionInvariantError
       (AuthoritySubmissionDecision, AuthorityAdmissionAggregate)
stepAuthoritySubmission aggregate client seqNo digest = do
  decision <- decideAuthoritySubmission aggregate client seqNo digest
  case decision of
    AuthoritySubmissionDecided accepted@(SubmissionAccepted operationId) ->
      let ledger = authorityAggregateSubmissionLedger aggregate
          nextLedger = snd (stepSubmit (operationIdEpoch operationId) ledger client seqNo digest)
          next =
            aggregate
              { authorityAggregateSubmissionLedger = nextLedger
              , authorityAggregateSubmissionEpochs =
                  Map.insert
                    (client, seqNo)
                    (operationIdEpoch operationId)
                    (authorityAggregateSubmissionEpochs aggregate)
              }
       in Right (AuthoritySubmissionDecided accepted, next)
    _ -> Right (decision, aggregate)

authoritySubmissionStatus
  :: AuthorityAdmissionAggregate
  -> ClientId
  -> ClientSequence
  -> SubmissionStatus
authoritySubmissionStatus aggregate client seqNo =
  submissionStatus client seqNo (authorityAggregateSubmissionLedger aggregate)

lookupSubmissionRecord
  :: SubmissionLedger
  -> ClientId
  -> ClientSequence
  -> Maybe SubmissionRecord
lookupSubmissionRecord ledger client seqNo =
  Map.lookup client (submissionClients ledger) >>= Map.lookup seqNo . clientRecords

submissionRecordDigest :: SubmissionRecord -> RequestDigest
submissionRecordDigest record = case record of
  SubmissionInFlight digest -> digest
  SubmissionSettled digest _ -> digest

sequenceExpired :: SubmissionLedger -> ClientId -> ClientSequence -> Bool
sequenceExpired ledger client seqNo =
  case Map.lookup client (submissionClients ledger) of
    Nothing -> False
    Just submissions -> seqNo <= clientSequenceFloor submissions

retainedSubmissionCount :: SubmissionLedger -> Natural
retainedSubmissionCount = fromIntegral . Set.size . submissionKeySet
