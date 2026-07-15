{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Sprint 1.61: the closed, result-indexed capability program. A
-- @'CapabilityProgram' k result@ is the only way to request work against a
-- capability, and three facts fall out of its type:
--
--   * a read/availability kind CANNOT be a mutation program — the mutation
--     constructors demand an 'InternalCasKind'/'ExternalIntentKind' instance, and
--     those instance sets are closed, so a read kind yields an unsatisfiable
--     constraint (a compile error);
--   * the mutation arms have NO coordinate field — the target is fixed by the
--     opaque permit / verified intent, which came from the observed reference;
--   * the result is pinned per constructor (a GADT, no type family), so an
--     'Observe' yields a 'CapabilityObservation' and only 'InternalCas' yields a
--     'CasOutcome'.
--
-- GADT constructors have nominal roles automatically, so the operation index
-- cannot be coerced across programs.
module Prodbox.ControlPlane.Program
  ( ExpectedVersion (..)
  , PayloadDigest (..)
  , CasOutcome (..)
  , CommitOutcome (..)
  , CapabilityProgram (..)
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind
  , ExternalIntentKind
  , InternalCasKind
  )
import Prodbox.ControlPlane.Observation
  ( CapabilityObservation
  , FreshnessWindow
  )
import Prodbox.ControlPlane.Permit
  ( VerifiedIntent
  , WriterPermit
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBObjectVersion)
import Prodbox.Lifecycle.TargetCommitIntent (TargetValueDigest)

-- | The store version an internal CAS expects to replace.
newtype ExpectedVersion = ExpectedVersion ModelBObjectVersion
  deriving (Eq, Show)

-- | The digest of the payload an internal CAS writes.
newtype PayloadDigest = PayloadDigest TargetValueDigest
  deriving (Eq, Show)

data CasOutcome
  = CasApplied !ModelBObjectVersion
  | CasConflict !Text
  | CasRefused !Text
  deriving (Eq, Show)

data CommitOutcome
  = CommitApplied !Text
  | CommitRejected !Text
  deriving (Eq, Show)

data CapabilityProgram (k :: CapabilityKind) result where
  -- | Observe is total over EVERY kind and coordinate-free (only a freshness
  -- request); it yields an observation bound to the reference it ran against.
  Observe
    :: FreshnessWindow
    -> CapabilityProgram k (CapabilityObservation k)
  -- | Internal authority CAS: gated to an 'InternalCasKind' at compile time and
  -- carrying an opaque writer permit; no coordinate field (the permit fixes it).
  InternalCas
    :: (InternalCasKind k)
    => WriterPermit k
    -> ExpectedVersion
    -> PayloadDigest
    -> CapabilityProgram k CasOutcome
  -- | External provider/target/destroy commit: gated to an 'ExternalIntentKind'
  -- and carrying a verified (signed) intent; no coordinate field.
  ExternalCommit
    :: (ExternalIntentKind k)
    => VerifiedIntent k
    -> CapabilityProgram k CommitOutcome
