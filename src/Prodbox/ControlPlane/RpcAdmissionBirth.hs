{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Explicit write-ahead admission modes. Only public seed metadata and an
-- opaque encrypted-store revision identify the predecessor; legacy payloads
-- are never hashed into a registration receipt.
module Prodbox.ControlPlane.RpcAdmissionBirth
  ( RpcBirthPhase (..)
  , RpcBirthPhaseWitness (..)
  , RpcBirthTransition (..)
  , RpcBirthStage
  , RpcBirthRecord
  , RpcBirthRecordFormat (..)
  , rpcBirthRecordFormat
  , RpcBirthDescriptor
  , RpcBirthMarker
  , RpcBirthMarkerPhase (..)
  , RpcBirthError (..)
  , RpcBirthServingMode
  , legacyRpcBirthServingMode
  , registeredRpcBirthServingMode
  , rpcBirthServingModeRequiresRegistration
  , rpcBirthServingModeMatches
  , mkRpcBirthDescriptor
  , rpcBirthDescriptorGeneration
  , rpcBirthDescriptorKey
  , rpcBirthDescriptorScope
  , rpcBirthDescriptorEpoch
  , rpcBirthDescriptorDeadline
  , rpcBirthDescriptorRevision
  , rpcBirthDescriptorSeedDigest
  , rpcBirthDescriptorDigest
  , rpcBirthDescriptorCapacity
  , rpcBirthDescriptorReservations
  , encodeRpcBirthDescriptor
  , decodeRpcBirthDescriptor
  , rpcBirthDescriptorMaximumBytes
  , confirmRpcBirthPrimaryObservation
  , rpcBirthPhase
  , rpcBirthDescriptor
  , rpcBirthCandidate
  , rpcBirthPublicSeed
  , rpcBirthAdmission
  , rpcBirthLegacy
  , replaceRpcBirthAdmission
  , rpcBirthStage
  , rpcBirthStageRecord
  , prepareRpcBirth
  , validateRpcBirthPredecessor
  , advanceRpcBirth
  , rpcBirthMarkerFor
  , rpcBirthMarkerPhase
  , rpcBirthMarkerScope
  , rpcBirthMarkerMatches
  , rpcBirthMarkerGeneration
  , rpcBirthMarkerDescriptorDigest
  , rpcBirthMarkerCodec
  , rpcBirthRecordCodec
  , rpcBirthPinnedRecordCodec
  , rpcBirthSeedDigest
  , rpcBirthOriginalHomeSeed
  , rpcBirthMarkerMaximumBytes
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.List (minimumBy)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (controlPlaneSigningKeyPrincipal)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( authorityAdmissionStateCodec
  , authorityAdmissionStateCodecWithRegisteredClients
  , authorityAdmissionStateCodecWithRegisteredRpc
  )
import Prodbox.ControlPlane.CallerPrincipal (allCallerPrincipals)
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.RpcClientRegistration (validateRpcRegisteredClients)
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityDecommissionState (..)
  , AuthorityMigrationMode (..)
  , authorityAggregateAuthenticationEpoch
  , authorityAggregateDecommission
  , authorityAggregateMigration
  , authorityAggregateRegisteredClients
  , authorityAggregateRpcKeyRegistry
  , authorityAggregateSubmissionLedger
  , seedAuthorityRpcKeyRegistry
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredClientTable
  , registeredClientMaximumReservations
  , registeredClientMaximumSlots
  , registeredClientTableCapacity
  , registeredClientTableSpecifications
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (MigrationWritersQuiesced)
  , migrationAuthorityStatus
  )
import Prodbox.Lifecycle.Authority.Submission (liveSubmissionCount)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , mkModelBObjectVersion
  , modelBObjectVersionText
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros, authorityTimeMicros)

data RpcBirthPhase
  = BirthLegacy
  | BirthPrepared
  | BirthArmed
  | BirthCommitted
  | BirthRetiring
  | BirthRetired
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data RpcBirthPhaseWitness phase where
  PreparedBirth :: RpcBirthPhaseWitness 'BirthPrepared
  ArmedBirth :: RpcBirthPhaseWitness 'BirthArmed
  CommittedBirth :: RpcBirthPhaseWitness 'BirthCommitted
  RetiringBirth :: RpcBirthPhaseWitness 'BirthRetiring
  RetiredBirth :: RpcBirthPhaseWitness 'BirthRetired

data RpcBirthTransition from to where
  ArmRpcBirth :: RpcBirthTransition 'BirthPrepared 'BirthArmed
  CommitRpcBirth :: RpcBirthTransition 'BirthArmed 'BirthCommitted
  RetirePreparedRpcBirth :: RpcBirthTransition 'BirthPrepared 'BirthRetiring
  RetireArmedRpcBirth :: RpcBirthTransition 'BirthArmed 'BirthRetiring
  FinishRpcBirthRetirement :: RpcBirthTransition 'BirthRetiring 'BirthRetired

type role RpcBirthStage nominal
newtype RpcBirthStage (phase :: RpcBirthPhase) = RpcBirthStage RpcBirthRecord

-- This descriptor contains no legacy payload or digest of one.
data RpcBirthDescriptor
  = RpcBirthDescriptor
      !AuthorityScope
      !Natural
      !Text
      !AuthorityEpoch
      !AuthorityTime
      !ModelBObjectVersion
      !Text
      !Natural
      !Natural
  deriving stock (Eq, Show)

data RpcBirthRecordFormat = RpcBirthHistoricalV1 | RpcBirthDurableV2
  deriving stock (Eq, Show)

data RpcBirthRecord
  = LegacyRpcBirthRecord !AuthorityAdmissionAggregate
  | PhasedRpcBirthRecord
      !RpcBirthRecordFormat
      !RpcBirthPhase
      !RpcBirthDescriptor
      !(Maybe RpcKeyRegistry)
      !AuthorityAdmissionAggregate
  deriving stock (Eq)

instance Show RpcBirthRecord where
  show record = "RpcBirthRecord {phase = " <> show (rpcBirthPhase record) <> "}"

data RpcBirthMarkerPhase = BirthMarkerPrepared | BirthMarkerCommitted | BirthMarkerRetired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RpcBirthMarker = RpcBirthMarker !AuthorityScope !Natural !Text !RpcBirthMarkerPhase
  deriving stock (Eq, Show)

data RpcBirthError
  = RpcBirthDescriptorInvalid
  | RpcBirthScopeMismatch
  | RpcBirthProfileMismatch
  | RpcBirthSeedInvalid
  | RpcBirthSeedChanged
  | RpcBirthLegacyStateRequired
  | RpcBirthRegisteredStateUnbound
  | RpcBirthGenerationMismatch
  | RpcBirthAlreadyCommitted
  | RpcBirthWrongPhase
  | RpcBirthMarkerMismatch
  | RpcBirthMarkerMissing
  | RpcBirthAdmissionMissing
  | RpcBirthObservationUnavailable
  | RpcBirthWriteUnconfirmed
  | RpcBirthDeadlineReached
  | RpcBirthClockUnavailable
  | RpcBirthEffectTimedOut
  | RpcBirthRequestInvalid
  | RpcBirthRequestContextInvalid
  | RpcBirthNativeSourceUnavailable
  | RpcBirthNativeSourceChanged
  | RpcBirthNativeCompatibilityMismatch
  | RpcBirthStateInvalid
  | RpcBirthStateTooLarge
  | RpcBirthPublicationRequired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- The serving pin comes from the mounted role configuration, not a request.
-- A registered runtime cannot interpret two missing objects as legacy bootstrap.
data RpcBirthServingMode = RpcBirthLegacyMode | RpcBirthRegisteredMode !AuthorityScope !Natural !Text
  deriving stock (Eq, Show)

legacyRpcBirthServingMode :: RpcBirthServingMode
legacyRpcBirthServingMode = RpcBirthLegacyMode

registeredRpcBirthServingMode
  :: AuthorityScope -> Natural -> Text -> Either RpcBirthError RpcBirthServingMode
registeredRpcBirthServingMode scope generation digest = do
  unless
    ( generation > 0
        && generation <= fromIntegral (maxBound :: Word64)
        && Text.length digest == 64
        && Text.all lowerHex digest
    )
    (Left RpcBirthDescriptorInvalid)
  pure (RpcBirthRegisteredMode scope generation digest)

rpcBirthServingModeRequiresRegistration :: RpcBirthServingMode -> Bool
rpcBirthServingModeRequiresRegistration mode = case mode of
  RpcBirthLegacyMode -> False
  RpcBirthRegisteredMode {} -> True

rpcBirthServingModeMatches :: RpcBirthServingMode -> RpcBirthDescriptor -> Bool
rpcBirthServingModeMatches mode descriptor = case mode of
  RpcBirthLegacyMode -> False
  RpcBirthRegisteredMode scope generation digest ->
    scope == rpcBirthDescriptorScope descriptor
      && generation == rpcBirthDescriptorGeneration descriptor
      && digest == rpcBirthDescriptorDigest descriptor

mkRpcBirthDescriptor
  :: AuthorityScope
  -> Natural
  -> Text
  -> AuthorityEpoch
  -> AuthorityTime
  -> ModelBObjectVersion
  -> RpcKeyRegistry
  -> RegisteredClientTable
  -> Either RpcBirthError RpcBirthDescriptor
mkRpcBirthDescriptor scope generation key epoch deadline revision seed clients = do
  unless
    (generation > 0 && generation <= fromIntegral (maxBound :: Word64))
    (Left RpcBirthDescriptorInvalid)
  unless (Text.length key == 32 && Text.all lowerHex key) (Left RpcBirthDescriptorInvalid)
  unless
    (authorityEpochValue epoch > 0 && authorityTimeMicros deadline > 0)
    (Left RpcBirthDescriptorInvalid)
  unless (rpcKeyRegistryScope seed == scope) (Left RpcBirthScopeMismatch)
  digest <- rpcBirthSeedDigest seed
  reservations <- case registeredClientTableSpecifications clients of
    [] -> Left RpcBirthProfileMismatch
    spec : _ -> Right (registeredClientMaximumReservations spec)
  unless
    ( all
        ((== reservations) . registeredClientMaximumReservations)
        (registeredClientTableSpecifications clients)
    )
    (Left RpcBirthProfileMismatch)
  pure
    ( RpcBirthDescriptor
        scope
        generation
        key
        epoch
        deadline
        revision
        digest
        (registeredClientTableCapacity clients)
        reservations
    )

rpcBirthDescriptorScope :: RpcBirthDescriptor -> AuthorityScope
rpcBirthDescriptorScope (RpcBirthDescriptor value _ _ _ _ _ _ _ _) = value
rpcBirthDescriptorGeneration :: RpcBirthDescriptor -> Natural
rpcBirthDescriptorGeneration (RpcBirthDescriptor _ value _ _ _ _ _ _ _) = value
rpcBirthDescriptorKey :: RpcBirthDescriptor -> Text
rpcBirthDescriptorKey (RpcBirthDescriptor _ _ value _ _ _ _ _ _) = value
rpcBirthDescriptorEpoch :: RpcBirthDescriptor -> AuthorityEpoch
rpcBirthDescriptorEpoch (RpcBirthDescriptor _ _ _ value _ _ _ _ _) = value
rpcBirthDescriptorDeadline :: RpcBirthDescriptor -> AuthorityTime
rpcBirthDescriptorDeadline (RpcBirthDescriptor _ _ _ _ value _ _ _ _) = value
rpcBirthDescriptorRevision :: RpcBirthDescriptor -> ModelBObjectVersion
rpcBirthDescriptorRevision (RpcBirthDescriptor _ _ _ _ _ value _ _ _) = value
rpcBirthDescriptorSeedDigest :: RpcBirthDescriptor -> Text
rpcBirthDescriptorSeedDigest (RpcBirthDescriptor _ _ _ _ _ _ value _ _) = value
rpcBirthDescriptorCapacity :: RpcBirthDescriptor -> Natural
rpcBirthDescriptorCapacity (RpcBirthDescriptor _ _ _ _ _ _ _ value _) = value
rpcBirthDescriptorReservations :: RpcBirthDescriptor -> Natural
rpcBirthDescriptorReservations (RpcBirthDescriptor _ _ _ _ _ _ _ _ value) = value

-- Successful snapshots require the same opaque revision around the marker.
-- Closing failures retain their own recovery evidence; an unavailable closing
-- read cannot establish stable corruption from an earlier sample.
confirmRpcBirthPrimaryObservation
  :: ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthRecord
confirmRpcBirthPrimaryObservation record confirmation = case confirmation of
  ModelBCorrupt _ -> confirmation
  ModelBEndpointUnready _ -> confirmation
  ModelBUnobservable _ -> confirmation
  ModelBMissing -> case record of
    ModelBMissing -> confirmation
    _ -> changed
  ModelBObserved revision _ -> case record of
    ModelBObserved previous _ | previous == revision -> confirmation
    _ -> changed
 where
  changed = ModelBUnobservable "RpcBirthSnapshotChanged"

rpcBirthPhase :: RpcBirthRecord -> RpcBirthPhase
rpcBirthPhase record = case record of
  LegacyRpcBirthRecord _ -> BirthLegacy
  PhasedRpcBirthRecord _ phase _ _ _ -> phase
rpcBirthRecordFormat :: RpcBirthRecord -> Maybe RpcBirthRecordFormat
rpcBirthRecordFormat record = case record of
  LegacyRpcBirthRecord _ -> Nothing
  PhasedRpcBirthRecord format _ _ _ _ -> Just format
rpcBirthDescriptor :: RpcBirthRecord -> Maybe RpcBirthDescriptor
rpcBirthDescriptor record = case record of
  LegacyRpcBirthRecord _ -> Nothing
  PhasedRpcBirthRecord _ _ descriptor _ _ -> Just descriptor
rpcBirthCandidate :: RpcBirthRecord -> Maybe RpcKeyRegistry
rpcBirthCandidate record = case rpcBirthPhase record of
  BirthLegacy -> Nothing
  BirthPrepared -> rpcBirthPublicSeed record
  BirthArmed -> rpcBirthPublicSeed record
  BirthCommitted -> Nothing
  BirthRetiring -> Nothing
  BirthRetired -> Nothing
rpcBirthPublicSeed :: RpcBirthRecord -> Maybe RpcKeyRegistry
rpcBirthPublicSeed record = case record of
  LegacyRpcBirthRecord _ -> Nothing
  PhasedRpcBirthRecord _ _ _ seed _ -> seed
rpcBirthAdmission :: RpcBirthRecord -> AuthorityAdmissionAggregate
rpcBirthAdmission record = case record of
  LegacyRpcBirthRecord value -> value
  PhasedRpcBirthRecord _ _ _ _ value -> value

rpcBirthLegacy :: AuthorityAdmissionAggregate -> Either RpcBirthError RpcBirthRecord
rpcBirthLegacy aggregate = do
  unless (authorityAggregateRpcKeyRegistry aggregate == Nothing) (Left RpcBirthRegisteredStateUnbound)
  pure (LegacyRpcBirthRecord aggregate)

-- Normal clients can change only an already selected serving projection.
replaceRpcBirthAdmission
  :: RpcBirthRecord -> AuthorityAdmissionAggregate -> Either RpcBirthError RpcBirthRecord
replaceRpcBirthAdmission previous aggregate = case previous of
  LegacyRpcBirthRecord _ -> rpcBirthLegacy aggregate
  PhasedRpcBirthRecord format phase descriptor seed _ -> case phase of
    BirthCommitted -> checked (PhasedRpcBirthRecord RpcBirthDurableV2 phase descriptor Nothing aggregate)
    BirthRetired -> checked (PhasedRpcBirthRecord format phase descriptor seed aggregate)
    BirthLegacy -> Left RpcBirthStateInvalid
    BirthPrepared -> Left RpcBirthWrongPhase
    BirthArmed -> Left RpcBirthWrongPhase
    BirthRetiring -> Left RpcBirthWrongPhase
   where
    checked next = validateRecord (rpcBirthDescriptorScope descriptor) next >> pure next

rpcBirthStage :: RpcBirthPhaseWitness phase -> RpcBirthRecord -> Maybe (RpcBirthStage phase)
rpcBirthStage witness record
  | rpcBirthPhase record == wanted = Just (RpcBirthStage record)
  | otherwise = Nothing
 where
  wanted = case witness of
    PreparedBirth -> BirthPrepared
    ArmedBirth -> BirthArmed
    CommittedBirth -> BirthCommitted
    RetiringBirth -> BirthRetiring
    RetiredBirth -> BirthRetired
rpcBirthStageRecord :: RpcBirthStage phase -> RpcBirthRecord
rpcBirthStageRecord (RpcBirthStage value) = value

validateRpcBirthPredecessor :: AuthorityAdmissionAggregate -> Either RpcBirthError ()
validateRpcBirthPredecessor aggregate = do
  unless
    ( authorityAggregateDecommission aggregate == AuthorityServing
        && authorityAggregateRpcKeyRegistry aggregate == Nothing
        && liveSubmissionCount (authorityAggregateSubmissionLedger aggregate) == 0
    )
    (Left RpcBirthLegacyStateRequired)
  case authorityAggregateMigration aggregate of
    AuthorityCleanInstall -> Left RpcBirthLegacyStateRequired
    AuthorityMigrationControlled migration ->
      unless
        (migrationAuthorityStatus migration == MigrationWritersQuiesced)
        (Left RpcBirthLegacyStateRequired)

prepareRpcBirth
  :: RpcBirthDescriptor
  -> RpcKeyRegistry
  -> RpcBirthRecord
  -> Either RpcBirthError (RpcBirthStage 'BirthPrepared)
prepareRpcBirth descriptor seed previous = do
  let aggregate = rpcBirthAdmission previous
      expectedGeneration = maybe 1 ((+ 1) . rpcBirthDescriptorGeneration) (rpcBirthDescriptor previous)
  validateRpcBirthPredecessor aggregate
  unless (rpcBirthPhase previous `elem` [BirthLegacy, BirthRetired]) (Left RpcBirthWrongPhase)
  unless
    (rpcBirthDescriptorGeneration descriptor == expectedGeneration)
    (Left RpcBirthGenerationMismatch)
  unless
    (rpcBirthDescriptorEpoch descriptor == authorityAggregateAuthenticationEpoch aggregate)
    (Left RpcBirthRequestContextInvalid)
  digest <- rpcBirthSeedDigest seed
  unless
    ( registeredClientTableCapacity (authorityAggregateRegisteredClients aggregate)
        == rpcBirthDescriptorCapacity descriptor
        && all
          ((== rpcBirthDescriptorReservations descriptor) . registeredClientMaximumReservations)
          (registeredClientTableSpecifications (authorityAggregateRegisteredClients aggregate))
    )
    (Left RpcBirthProfileMismatch)
  unless (digest == rpcBirthDescriptorSeedDigest descriptor) (Left RpcBirthSeedChanged)
  -- Validation also proves unchanged home identities/capacity and a closed gate.
  _ <-
    first
      (const RpcBirthSeedInvalid)
      (seedAuthorityRpcKeyRegistry (rpcBirthDescriptorScope descriptor) seed aggregate)
  pure
    ( RpcBirthStage
        (PhasedRpcBirthRecord RpcBirthDurableV2 BirthPrepared descriptor (Just seed) aggregate)
    )

advanceRpcBirth
  :: RpcBirthTransition from to
  -> RpcBirthStage from
  -> Maybe RpcBirthMarker
  -> Either RpcBirthError (RpcBirthStage to)
advanceRpcBirth transition (RpcBirthStage record) marker = do
  descriptor <- maybe (Left RpcBirthDescriptorInvalid) Right (rpcBirthDescriptor record)
  let aggregate = rpcBirthAdmission record
      candidate = rpcBirthPublicSeed record
      unchanged :: RpcBirthPhase -> Maybe RpcKeyRegistry -> RpcBirthStage phase
      unchanged phase seed = RpcBirthStage (PhasedRpcBirthRecord RpcBirthDurableV2 phase descriptor seed aggregate)
      require phase =
        unless (maybe False (rpcBirthMarkerMatches phase descriptor) marker) (Left RpcBirthMarkerMismatch)
      retire :: Either RpcBirthError (RpcBirthStage 'BirthRetiring)
      retire = do
        case marker of
          Nothing -> Right ()
          Just value ->
            unless
              ( rpcBirthMarkerMatches BirthMarkerPrepared descriptor value
                  || ( rpcBirthMarkerPhase value == BirthMarkerRetired
                         && rpcBirthMarkerScope value == rpcBirthDescriptorScope descriptor
                         && rpcBirthMarkerGeneration value + 1 == rpcBirthDescriptorGeneration descriptor
                     )
              )
              (Left RpcBirthMarkerMismatch)
        seed <- maybe (Left RpcBirthSeedInvalid) Right candidate
        pure (unchanged BirthRetiring (Just seed))
  case transition of
    ArmRpcBirth -> require BirthMarkerPrepared >> pure (unchanged BirthArmed candidate)
    CommitRpcBirth -> do
      require BirthMarkerPrepared
      seed <- maybe (Left RpcBirthSeedInvalid) Right candidate
      next <-
        first
          (const RpcBirthSeedInvalid)
          (seedAuthorityRpcKeyRegistry (rpcBirthDescriptorScope descriptor) seed aggregate)
      pure (RpcBirthStage (PhasedRpcBirthRecord RpcBirthDurableV2 BirthCommitted descriptor Nothing next))
    RetirePreparedRpcBirth -> retire
    RetireArmedRpcBirth -> require BirthMarkerPrepared >> retire
    FinishRpcBirthRetirement -> do
      require BirthMarkerRetired
      case candidate of
        Just seed -> pure (unchanged BirthRetired (Just seed))
        Nothing -> case rpcBirthRecordFormat record of
          Just RpcBirthHistoricalV1 ->
            pure
              (RpcBirthStage (PhasedRpcBirthRecord RpcBirthHistoricalV1 BirthRetired descriptor Nothing aggregate))
          Just RpcBirthDurableV2 -> Left RpcBirthSeedInvalid
          Nothing -> Left RpcBirthSeedInvalid

rpcBirthMarkerFor :: RpcBirthMarkerPhase -> RpcBirthDescriptor -> RpcBirthMarker
rpcBirthMarkerFor phase descriptor =
  RpcBirthMarker
    (rpcBirthDescriptorScope descriptor)
    (rpcBirthDescriptorGeneration descriptor)
    (rpcBirthDescriptorDigest descriptor)
    phase
rpcBirthMarkerScope :: RpcBirthMarker -> AuthorityScope
rpcBirthMarkerScope (RpcBirthMarker scope _ _ _) = scope
rpcBirthMarkerPhase :: RpcBirthMarker -> RpcBirthMarkerPhase
rpcBirthMarkerPhase (RpcBirthMarker _ _ _ phase) = phase
rpcBirthMarkerGeneration :: RpcBirthMarker -> Natural
rpcBirthMarkerGeneration (RpcBirthMarker _ value _ _) = value
rpcBirthMarkerDescriptorDigest :: RpcBirthMarker -> Text
rpcBirthMarkerDescriptorDigest (RpcBirthMarker _ _ value _) = value
rpcBirthMarkerMatches :: RpcBirthMarkerPhase -> RpcBirthDescriptor -> RpcBirthMarker -> Bool
rpcBirthMarkerMatches phase descriptor marker = marker == rpcBirthMarkerFor phase descriptor

rpcBirthSeedDigest :: RpcKeyRegistry -> Either RpcBirthError Text
rpcBirthSeedDigest = fmap publicDigest . first (const RpcBirthSeedInvalid) . encodeRpcKeyRegistry

publicDigest :: ByteString -> Text
publicDigest = Text.pack . concatMap hex . BS.unpack . SHA256.hash
 where
  hex byte = let rendered = showHex byte "" in if length rendered == 1 then '0' : rendered else rendered
lowerHex :: Char -> Bool
lowerHex value =
  (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')

data DescriptorWire = DescriptorWire !Text !Natural !Text !Natural !Natural !Text !Text !Natural !Natural
  deriving stock (Generic)
  deriving anyclass (Serialise)
data RecordWire = RecordWire !Word !RpcBirthPhase !DescriptorWire !(Maybe ByteString) !ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)
data MarkerWire = MarkerWire !Word !Text !Natural !Text !RpcBirthMarkerPhase
  deriving stock (Generic)
  deriving anyclass (Serialise)

descriptorWire :: RpcBirthDescriptor -> DescriptorWire
descriptorWire descriptor =
  DescriptorWire
    (authorityScopeText (rpcBirthDescriptorScope descriptor))
    (rpcBirthDescriptorGeneration descriptor)
    (rpcBirthDescriptorKey descriptor)
    (authorityEpochValue (rpcBirthDescriptorEpoch descriptor))
    (authorityTimeMicros (rpcBirthDescriptorDeadline descriptor))
    (modelBObjectVersionText (rpcBirthDescriptorRevision descriptor))
    (rpcBirthDescriptorSeedDigest descriptor)
    (rpcBirthDescriptorCapacity descriptor)
    (rpcBirthDescriptorReservations descriptor)
rpcBirthDescriptorDigest :: RpcBirthDescriptor -> Text
rpcBirthDescriptorDigest = publicDigest . Lazy.toStrict . serialise . descriptorWire

rpcBirthDescriptorMaximumBytes :: Int
rpcBirthDescriptorMaximumBytes = 4096

descriptorPrefix :: ByteString
descriptorPrefix = "prodbox-rpc-birth-descriptor-value/v1\NUL"

-- The public descriptor contains no admission payload, native key or receipt
-- hash of a secret. Its independent wire leaves all retained codecs unchanged.
encodeRpcBirthDescriptor :: RpcBirthDescriptor -> Either RpcBirthError ByteString
encodeRpcBirthDescriptor descriptor = do
  let bytes = descriptorPrefix <> Lazy.toStrict (serialise (descriptorWire descriptor))
  unless (BS.length bytes <= rpcBirthDescriptorMaximumBytes) (Left RpcBirthStateTooLarge)
  _ <- decodeRpcBirthDescriptor (rpcBirthDescriptorScope descriptor) bytes
  pure bytes

decodeRpcBirthDescriptor :: AuthorityScope -> ByteString -> Either RpcBirthError RpcBirthDescriptor
decodeRpcBirthDescriptor scope bytes = do
  unless (BS.length bytes <= rpcBirthDescriptorMaximumBytes) (Left RpcBirthStateTooLarge)
  body <- maybe (Left RpcBirthDescriptorInvalid) Right (BS.stripPrefix descriptorPrefix bytes)
  wire <- first (const RpcBirthDescriptorInvalid) (parseCanonical rpcBirthDescriptorMaximumBytes body)
  parseDescriptor scope wire

parseDescriptor :: AuthorityScope -> DescriptorWire -> Either RpcBirthError RpcBirthDescriptor
parseDescriptor expected (DescriptorWire rawScope generation key epoch deadline rawRevision digest capacity reservations) = do
  scope <- first (const RpcBirthDescriptorInvalid) (mkAuthorityScope rawScope)
  unless (scope == expected) (Left RpcBirthScopeMismatch)
  parsedEpoch <- maybe (Left RpcBirthDescriptorInvalid) Right (authorityEpochFromValue epoch)
  revision <- first (const RpcBirthDescriptorInvalid) (mkModelBObjectVersion rawRevision)
  unless
    ( generation > 0
        && generation <= fromIntegral (maxBound :: Word64)
        && Text.length key == 32
        && Text.all lowerHex key
        && deadline > 0
        && Text.length digest == 64
        && Text.all lowerHex digest
        && capacity > 0
        && capacity <= registeredClientMaximumSlots
        && reservations > 0
    )
    (Left RpcBirthDescriptorInvalid)
  pure
    ( RpcBirthDescriptor
        scope
        generation
        key
        parsedEpoch
        (authorityTimeFromMicros deadline)
        revision
        digest
        capacity
        reservations
    )

recordPrefix :: ByteString
recordPrefix = "prodbox-rpc-birth/v1\NUL"
rpcBirthMarkerMaximumBytes :: Int
rpcBirthMarkerMaximumBytes = 16 * 1024

rpcBirthMarkerCodec :: AuthorityScope -> ModelBCodec RpcBirthMarker
rpcBirthMarkerCodec expected = ModelBCodec encode decode
 where
  encode (RpcBirthMarker scope generation digest phase) = do
    unless (scope == expected) (Left "RpcBirthScopeMismatch")
    bounded
      rpcBirthMarkerMaximumBytes
      (Lazy.toStrict (serialise (MarkerWire 1 (authorityScopeText scope) generation digest phase)))
  decode bytes = do
    wire@(MarkerWire version rawScope generation digest phase) <-
      parseCanonical rpcBirthMarkerMaximumBytes bytes
    unless
      ( version == 1
          && generation > 0
          && generation <= fromIntegral (maxBound :: Word64)
          && Text.length digest == 64
          && Text.all lowerHex digest
      )
      (Left "RpcBirthDescriptorInvalid")
    scope <- first (const "RpcBirthDescriptorInvalid") (mkAuthorityScope rawScope)
    unless (scope == expected) (Left "RpcBirthScopeMismatch")
    unless (Lazy.toStrict (serialise wire) == bytes) (Left "RpcBirthStateInvalid")
    pure (RpcBirthMarker scope generation digest phase)

rpcBirthRecordCodec
  :: Int
  -> Natural
  -> Natural
  -> AuthorityScope
  -> RegisteredClientTable
  -> ModelBCodec RpcBirthRecord
rpcBirthRecordCodec maximumBytes live retained scope legacyClients =
  rpcBirthRecordCodecFor
    maximumBytes
    live
    retained
    scope
    (authorityAdmissionStateCodecWithRegisteredClients maximumBytes live retained legacyClients)
    (const (Right ()))

-- The independent mounted pin selects this reader. The old inner aggregate
-- remains self-contained; its table is checked against the retained descriptor,
-- rather than against a table reconstructed from native latest keys.
rpcBirthPinnedRecordCodec
  :: Int
  -> Natural
  -> Natural
  -> AuthorityScope
  -> RpcBirthServingMode
  -> Either RpcBirthError (ModelBCodec RpcBirthRecord)
rpcBirthPinnedRecordCodec maximumBytes live retained scope mode = do
  unless (rpcBirthServingModeRequiresRegistration mode) (Left RpcBirthPublicationRequired)
  pure
    ( rpcBirthRecordCodecFor
        maximumBytes
        live
        retained
        scope
        (authorityAdmissionStateCodec maximumBytes live retained)
        checkPin
    )
 where
  checkPin record = case rpcBirthDescriptor record of
    Nothing -> Left "RpcBirthRegisteredStateUnbound"
    Just descriptor ->
      unless (rpcBirthServingModeMatches mode descriptor) (Left "RpcBirthMarkerMismatch")

rpcBirthRecordCodecFor
  :: Int
  -> Natural
  -> Natural
  -> AuthorityScope
  -> ModelBCodec AuthorityAdmissionAggregate
  -> (RpcBirthRecord -> Either String ())
  -> ModelBCodec RpcBirthRecord
rpcBirthRecordCodecFor maximumBytes live retained scope legacyCodec checkPin = ModelBCodec encode decode
 where
  registeredCodec descriptor =
    authorityAdmissionStateCodecWithRegisteredRpc
      maximumBytes
      live
      retained
      scope
      (rpcBirthDescriptorCapacity descriptor)
      (rpcBirthDescriptorReservations descriptor)
  encode record = checkPin record >> encodeRecord record
  encodeRecord record = case record of
    LegacyRpcBirthRecord aggregate -> encodeModelBValue legacyCodec aggregate
    PhasedRpcBirthRecord format phase descriptor candidate aggregate -> do
      first show (validateRecord scope record)
      aggregateBytes <-
        encodeModelBValue
          (if phase == BirthCommitted then registeredCodec descriptor else legacyCodec)
          aggregate
      seedBytes <- traverse (first show . encodeRpcKeyRegistry) candidate
      bounded
        maximumBytes
        ( recordPrefix
            <> Lazy.toStrict
              (serialise (RecordWire (schema format) phase (descriptorWire descriptor) seedBytes aggregateBytes))
        )
  decode bytes = do
    _ <- bounded maximumBytes bytes
    case BS.stripPrefix recordPrefix bytes of
      Nothing -> do
        record <- LegacyRpcBirthRecord <$> decodeModelBValue legacyCodec bytes
        checkPin record
        pure record
      Just body -> do
        RecordWire version phase wire seedBytes aggregateBytes <- parseCanonical maximumBytes body
        format <- case version of
          1 -> Right RpcBirthHistoricalV1
          2 -> Right RpcBirthDurableV2
          _ -> Left "RpcBirthStateInvalid"
        unless (phase /= BirthLegacy) (Left "RpcBirthStateInvalid")
        descriptor <- first show (parseDescriptor scope wire)
        candidate <- traverse (first show . decodeRpcKeyRegistry) seedBytes
        aggregate <-
          decodeModelBValue
            (if phase == BirthCommitted then registeredCodec descriptor else legacyCodec)
            aggregateBytes
        let record = PhasedRpcBirthRecord format phase descriptor candidate aggregate
        first show (validateRecord scope record)
        checkPin record
        canonical <- encode record
        unless (canonical == bytes) (Left "RpcBirthStateInvalid")
        pure record
  schema format = case format of
    RpcBirthHistoricalV1 -> 1
    RpcBirthDurableV2 -> 2

validateRecord :: AuthorityScope -> RpcBirthRecord -> Either RpcBirthError ()
validateRecord scope record = case record of
  LegacyRpcBirthRecord aggregate ->
    unless (authorityAggregateRpcKeyRegistry aggregate == Nothing) (Left RpcBirthRegisteredStateUnbound)
  PhasedRpcBirthRecord format phase descriptor candidate aggregate -> do
    unless (rpcBirthDescriptorScope descriptor == scope) (Left RpcBirthScopeMismatch)
    unless
      ( registeredClientTableCapacity (authorityAggregateRegisteredClients aggregate)
          == rpcBirthDescriptorCapacity descriptor
          && all
            ((== rpcBirthDescriptorReservations descriptor) . registeredClientMaximumReservations)
            (registeredClientTableSpecifications (authorityAggregateRegisteredClients aggregate))
      )
      (Left RpcBirthProfileMismatch)
    case phase of
      BirthLegacy -> Left RpcBirthStateInvalid
      BirthPrepared -> validatePrepared descriptor candidate aggregate
      BirthArmed -> validatePrepared descriptor candidate aggregate
      BirthCommitted -> do
        unless
          (authorityAggregateAuthenticationEpoch aggregate >= rpcBirthDescriptorEpoch descriptor)
          (Left RpcBirthRequestContextInvalid)
        unless (candidate == Nothing) (Left RpcBirthStateInvalid)
        registry <-
          maybe (Left RpcBirthRegisteredStateUnbound) Right (authorityAggregateRpcKeyRegistry aggregate)
        original <- rpcBirthOriginalHomeSeed registry
        digest <- rpcBirthSeedDigest original
        unless (digest == rpcBirthDescriptorSeedDigest descriptor) (Left RpcBirthSeedChanged)
      BirthRetiring -> validateRetired format descriptor candidate aggregate
      BirthRetired -> validateRetired format descriptor candidate aggregate
 where
  validatePrepared descriptor candidate aggregate = do
    seed <- maybe (Left RpcBirthSeedInvalid) Right candidate
    unless (authorityAggregateRpcKeyRegistry aggregate == Nothing) (Left RpcBirthStateInvalid)
    _ <- first (const RpcBirthSeedInvalid) (seedAuthorityRpcKeyRegistry scope seed aggregate)
    digest <- rpcBirthSeedDigest seed
    unless
      ( digest == rpcBirthDescriptorSeedDigest descriptor
          && authorityAggregateAuthenticationEpoch aggregate == rpcBirthDescriptorEpoch descriptor
      )
      (Left RpcBirthSeedChanged)
  validateRetired format descriptor candidate aggregate = do
    unless (authorityAggregateRpcKeyRegistry aggregate == Nothing) (Left RpcBirthStateInvalid)
    case format of
      RpcBirthHistoricalV1 -> unless (candidate == Nothing) (Left RpcBirthStateInvalid)
      RpcBirthDurableV2 -> do
        seed <- maybe (Left RpcBirthSeedInvalid) Right candidate
        original <- rpcBirthOriginalHomeSeed seed
        unless (original == seed && rpcKeyRegistryScope seed == scope) (Left RpcBirthSeedInvalid)
        digest <- rpcBirthSeedDigest seed
        unless (digest == rpcBirthDescriptorSeedDigest descriptor) (Left RpcBirthSeedChanged)
        first
          (const RpcBirthProfileMismatch)
          (validateRpcRegisteredClients seed (authorityAggregateRegisteredClients aggregate))

rpcBirthOriginalHomeSeed :: RpcKeyRegistry -> Either RpcBirthError RpcKeyRegistry
rpcBirthOriginalHomeSeed registry = do
  let groups =
        Map.fromListWith
          (<>)
          [ ( controlPlaneSigningKeyPrincipal
                (rpcKeyOriginRef (rpcObservedOrigin (rpcKeyBindingObserved binding)))
            , [binding]
            )
          | binding <- rpcKeyRegistryBindings registry
          ]
  observed <- traverse (firstBinding groups) allCallerPrincipals
  first (const RpcBirthSeedInvalid) (seedLegacyRpcKeyRegistry (rpcKeyRegistryScope registry) observed)
 where
  firstBinding groups caller = case Map.lookup caller groups of
    Nothing -> Left RpcBirthSeedInvalid
    Just [] -> Left RpcBirthSeedInvalid
    Just bindings -> Right (rpcKeyBindingObserved (minimumBy (comparing rpcKeyBindingGeneration) bindings))

bounded :: Int -> ByteString -> Either String ByteString
bounded maximumBytes bytes
  | maximumBytes < 0 || BS.length bytes > maximumBytes = Left "RpcBirthStateTooLarge"
  | otherwise = Right bytes
parseCanonical :: (Serialise value) => Int -> ByteString -> Either String value
parseCanonical maximumBytes bytes = do
  _ <- bounded maximumBytes bytes
  value <- first (const "RpcBirthStateInvalid") (deserialiseOrFail (Lazy.fromStrict bytes))
  unless (Lazy.toStrict (serialise value) == bytes) (Left "RpcBirthStateInvalid")
  pure value
