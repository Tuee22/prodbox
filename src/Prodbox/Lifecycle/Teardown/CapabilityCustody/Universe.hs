{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Sprint 4.89: the closed universe of custodial capabilities and the indexed
-- disposition that must be produced before custody of one ends.
--
-- A __custodial capability__ is material whose possession is what makes a
-- resource destroyable — a Pulumi checkpoint, an access-key family, a sealed
-- credential generation.  It is deliberately distinct from the
-- operation-indexed reference to a live service boundary: a reference is how a
-- run /reaches/ a boundary, a custodial capability is what a run /holds/.  The
-- disambiguation is owned once, by
-- @documents\/engineering\/lifecycle_control_plane_architecture.md § 3.4@.
--
-- __There is no destroy constructor.__  Four constructors sit at the retire
-- index — the capability is already inert, it is discharged by proven absence
-- of everything it reaches, it is rotated onto a named successor, or it and the
-- identity it belongs to are destroyed jointly — and each carries a mandatory
-- strict discharge, so none is constructible from a capability alone.  One
-- constructor sits at the hold index.  That absence is the whole mechanism: a
-- destructive boundary takes the disposition multiset, so a caller holding a
-- capability and no discharge has nothing to pass.
--
-- Two AWS resources were stranded by the event this exists to prevent.  Both
-- depended on capabilities inside the retained store, and the store was
-- destroyed while they existed.
module Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( -- * The capability universe
    CustodialCapability (..)
  , custodialCapabilityUniverse
  , renderCustodialCapability

    -- * The custody index
  , CustodyIndex (..)

    -- * The disposition
  , CapabilityDisposition (..)
  , dispositionCapability
  , retireDispositionCount
  , holdDispositionCount

    -- * Discharges
  , InertnessProof (..)
  , DependantAbsenceProof (..)
  , SuccessorCapability (..)
  , JointDestructionProof (..)

    -- * What a checkpoint's observability says about custody
  , CheckpointCustodyObservation (..)

    -- * The durable projection a disposition travels as
  , CustodyDispositionKind (..)
  , CustodyDispositionRecord (..)
  , recordCapabilityDisposition
  , renderedCheckpointCapability
  , dispositionRecordDisposesCheckpoint
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass
  )
import Prodbox.Lifecycle.Teardown.Model
  ( RegisteredResourceKey
  , registeredResourceKeyText
  )

-- ---------------------------------------------------------------------------
-- The capability universe
-- ---------------------------------------------------------------------------

-- | Every kind of material this repository holds custody of.
--
-- Closed and enumerable, so a capability that gains a holder without gaining a
-- disposition is a build failure rather than an omission.
data CustodialCapability
  = -- | The encrypted Pulumi checkpoint of one registered stack.  Holding it is
    -- what makes that stack's resources destroyable at all.
    CheckpointCapability !RegisteredResourceKey
  | -- | One managed AWS credential family: its access keys and the sealed
    -- generations behind them.
    CredentialCapability !AwsCredentialClass
  | -- | The same stack's checkpoint after the Lifecycle Authority has retired
    -- its current reference into the retained list.
    --
    -- It exists so a retirement can name what the capability became.  Retiring
    -- a reference records it in the Authority's retained set and clears the
    -- live slot; the retained reference still names the backup copy's version,
    -- so the capability moved rather than ceased.  A run never /holds/ one of
    -- these — it is only ever a successor — which is why it is not enumerated
    -- by 'custodialCapabilityUniverse'.
    RetiredCheckpointCapability !RegisteredResourceKey
  deriving stock (Eq, Ord, Show)

renderCustodialCapability :: CustodialCapability -> Text
renderCustodialCapability = \case
  CheckpointCapability key ->
    "checkpoint/" <> registeredResourceKeyText key
  CredentialCapability credentialClass ->
    "credential/" <> Text.pack (show credentialClass)
  RetiredCheckpointCapability key ->
    "retired-checkpoint/" <> registeredResourceKeyText key

-- | The universe, derived from the compiled registries rather than authored.
--
-- Supplied by the caller that reads those registries, so this module stays a
-- vocabulary: see
-- "Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal".
custodialCapabilityUniverse
  :: [RegisteredResourceKey] -> [AwsCredentialClass] -> [CustodialCapability]
custodialCapabilityUniverse checkpointKeys credentialClasses =
  map CheckpointCapability checkpointKeys
    ++ map CredentialCapability credentialClasses

-- ---------------------------------------------------------------------------
-- The custody index
-- ---------------------------------------------------------------------------

-- | Whether a disposition keeps custody or ends it.
data CustodyIndex
  = CustodyHold
  | CustodyRetire
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Discharges
-- ---------------------------------------------------------------------------

-- | The capability authorises nothing: its keys are gone, its generation is
-- revoked, or its checkpoint holds no resources.
newtype InertnessProof = InertnessProof Text
  deriving stock (Eq, Ord, Show)

-- | Every resource the capability reaches was observed absent.  The set is the
-- derived dependant set, never one a caller chose.
newtype DependantAbsenceProof
  = DependantAbsenceProof [RegisteredResourceKey]
  deriving stock (Eq, Ord, Show)

-- | The capability was rotated onto a named successor that now reaches the
-- same resources.
newtype SuccessorCapability = SuccessorCapability CustodialCapability
  deriving stock (Eq, Ord, Show)

-- | The capability and the identity it belongs to were destroyed in one
-- operation, so nothing survives to be stranded.
newtype JointDestructionProof = JointDestructionProof Text
  deriving stock (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- The disposition
-- ---------------------------------------------------------------------------

-- | What happened to a capability, indexed by whether custody continues.
--
-- Every retire constructor takes a strict discharge, so none is constructible
-- from a capability alone, and there is deliberately no @CapabilityDestroyed@
-- arm: destruction without a discharge is the shape this type exists to make
-- unrepresentable.
data CapabilityDisposition (index :: CustodyIndex) where
  CapabilityHeld
    :: !CustodialCapability
    -> CapabilityDisposition 'CustodyHold
  CapabilityAlreadyInert
    :: !CustodialCapability
    -> !InertnessProof
    -> CapabilityDisposition 'CustodyRetire
  CapabilityDischargedByAbsence
    :: !CustodialCapability
    -> !DependantAbsenceProof
    -> CapabilityDisposition 'CustodyRetire
  CapabilityRotatedOnto
    :: !CustodialCapability
    -> !SuccessorCapability
    -> CapabilityDisposition 'CustodyRetire
  CapabilityDestroyedJointly
    :: !CustodialCapability
    -> !JointDestructionProof
    -> CapabilityDisposition 'CustodyRetire

deriving stock instance Eq (CapabilityDisposition index)

deriving stock instance Show (CapabilityDisposition index)

-- | Total over the universe, with no fall-through arm.
dispositionCapability :: CapabilityDisposition index -> CustodialCapability
dispositionCapability = \case
  CapabilityHeld capability -> capability
  CapabilityAlreadyInert capability _ -> capability
  CapabilityDischargedByAbsence capability _ -> capability
  CapabilityRotatedOnto capability _ -> capability
  CapabilityDestroyedJointly capability _ -> capability

-- | The counts the closure regression asserts, so a sixth constructor fails the
-- build rather than widening the universe silently.
retireDispositionCount :: Int
retireDispositionCount = 4

holdDispositionCount :: Int
holdDispositionCount = 1

-- ---------------------------------------------------------------------------
-- What a checkpoint's observability says about custody
-- ---------------------------------------------------------------------------

-- | The four arms of a checkpoint observation, restated here as a custody
-- question rather than a residue question.
--
-- The residue question is "is there a stack to destroy"; the custody question
-- is "does this run still hold what makes that stack destroyable". They have
-- different answers for the same observation, which is why they are different
-- types: an absent or empty checkpoint answers @ResidueAbsent@ to the first —
-- nothing to destroy — and @lost@ to the second, because the resources the
-- checkpoint reached may exist and nothing now names them.
--
-- Deliberately declared here rather than imported: the encrypted-backend
-- observability type lives beside a subprocess and a Vault session, and this
-- module is a vocabulary. The total map between them is owned by
-- "Prodbox.Lifecycle.LiveResidue", which already holds both.
data CheckpointCustodyObservation
  = CheckpointCapabilityPresent
  | CheckpointCapabilityAbsent
  | CheckpointCapabilityEmpty
  | CheckpointCapabilityCorrupt !Text
  deriving stock (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- The durable projection a disposition travels as
-- ---------------------------------------------------------------------------

-- | Which retire constructor a record projects.
--
-- Closed and enumerable, so a fifth retire constructor cannot travel as an
-- unrecognised one: 'recordCapabilityDisposition' is total and gains an arm or
-- fails to compile.
data CustodyDispositionKind
  = DispositionAlreadyInert
  | DispositionDischargedByAbsence
  | DispositionRotatedOnto
  | DispositionDestroyedJointly
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | What a retire-index disposition looks like once it has to cross a boundary
-- the type cannot cross.
--
-- The disposition itself is an indexed GADT and is deliberately not
-- 'Serialise': the point of the type is that it cannot be built without a
-- discharge, and a decoder is a way to build one.  What crosses instead is this
-- flat record, and it is __evidence rather than authority__: holding one
-- authorises nothing, and the surface that receives it decides what it admits.
--
-- The Lifecycle Authority is the receiving surface that matters.  It cannot
-- observe AWS, so it cannot check the proof; what it can do is refuse to retire
-- a reference for which no disposition was ever stated, which is the failure
-- that stranded two AWS resources.
data CustodyDispositionRecord = CustodyDispositionRecord
  { custodyDispositionCapability :: !Text
  , custodyDispositionKind :: !CustodyDispositionKind
  , custodyDispositionDetail :: !Text
  , custodyDispositionDependants :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Total over the retire index, with no fall-through arm.
recordCapabilityDisposition
  :: CapabilityDisposition 'CustodyRetire -> CustodyDispositionRecord
recordCapabilityDisposition disposition = case disposition of
  CapabilityAlreadyInert capability (InertnessProof proof) ->
    base capability DispositionAlreadyInert proof []
  CapabilityDischargedByAbsence capability (DependantAbsenceProof keys) ->
    base
      capability
      DispositionDischargedByAbsence
      "every resource this capability reaches was observed absent at the provider"
      (map registeredResourceKeyText keys)
  CapabilityRotatedOnto capability (SuccessorCapability successor) ->
    base
      capability
      DispositionRotatedOnto
      (renderCustodialCapability successor)
      []
  CapabilityDestroyedJointly capability (JointDestructionProof proof) ->
    base capability DispositionDestroyedJointly proof []
 where
  base capability kind detail dependants =
    CustodyDispositionRecord
      { custodyDispositionCapability = renderCustodialCapability capability
      , custodyDispositionKind = kind
      , custodyDispositionDetail = detail
      , custodyDispositionDependants = dependants
      }

-- | How a checkpoint capability renders for one registered stack name.
--
-- The Lifecycle Authority knows its registered checkpoints by name and has no
-- 'RegisteredResourceKey', so the comparison it makes is spelled once here
-- rather than as a string literal at the Authority.
renderedCheckpointCapability :: Text -> Text
renderedCheckpointCapability registeredName =
  "checkpoint/" <> registeredName

-- | Whether a record states a disposition for the checkpoint of one registered
-- stack name.
dispositionRecordDisposesCheckpoint :: Text -> CustodyDispositionRecord -> Bool
dispositionRecordDisposesCheckpoint registeredName record =
  custodyDispositionCapability record == renderedCheckpointCapability registeredName
