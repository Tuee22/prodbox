-- | Sprint 4.48: the retained Lifecycle Authority's in-force-config observe /
-- propose-CAS fold.
--
-- The Authority owns the immutable in-force configuration as a monotone
-- generation: a schema version, a content digest, and an opaque object reference
-- (the encrypted blob). It starts UNSEEDED and is seeded exactly once from the
-- bounded Tier-0 authority boot projection; thereafter every update is a
-- compare-and-set that advances the generation by one against the caller's
-- expected prior generation. A proposal whose schema is unsupported, whose
-- expected prior does not match the in-force generation, or that re-seeds an
-- already-seeded config is refused. Re-proposing the digest and schema already in
-- force is an idempotent no-op, so a lost response converges rather than forking a
-- generation.
--
-- This module is pure: it validates and CASes the schema\/generation\/digest\/
-- reference. Encryption, decryption, and role-scoped projection of the referenced
-- blob are the interpreter's; this fold owns the generation invariant.
module Prodbox.Lifecycle.Authority.Config
  ( -- * In-force config identity
    ConfigGeneration (..)
  , ConfigSchemaVersion (..)
  , ConfigDigest (..)
  , ConfigReference (..)
  , InForceConfig (..)

    -- * State
  , ConfigState (..)
  , initialConfigState
  , observeInForceConfig

    -- * Propose-CAS
  , ConfigProposal (..)
  , SchemaValidity (..)
  , ConfigProposeDecision (..)
  , ConfigProposeRefusal (..)
  , decideConfigPropose
  , applyConfigPropose
  , stepConfigPropose
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)

-- | A monotone in-force-config generation. A CAS update advances it by one.
newtype ConfigGeneration = ConfigGeneration Natural
  deriving (Eq, Ord, Show)

-- | The config schema version an in-force generation is validated against.
newtype ConfigSchemaVersion = ConfigSchemaVersion Natural
  deriving (Eq, Ord, Show)

-- | A digest over the canonical (non-secret) config projection.
newtype ConfigDigest = ConfigDigest Text
  deriving (Eq, Show)

-- | An opaque reference to the immutable encrypted config blob.
newtype ConfigReference = ConfigReference Text
  deriving (Eq, Show)

-- | One committed in-force config generation.
data InForceConfig = InForceConfig
  { inForceGeneration :: !ConfigGeneration
  , inForceSchema :: !ConfigSchemaVersion
  , inForceDigest :: !ConfigDigest
  , inForceReference :: !ConfigReference
  }
  deriving (Eq, Show)

-- | The authority config state: unseeded (pre-Tier-0-boot), or one in-force
-- generation.
data ConfigState
  = ConfigUnseeded
  | ConfigInForce !InForceConfig
  deriving (Eq, Show)

initialConfigState :: ConfigState
initialConfigState = ConfigUnseeded

-- | The current in-force config, or @Nothing@ before the Tier-0 seed.
observeInForceConfig :: ConfigState -> Maybe InForceConfig
observeInForceConfig state = case state of
  ConfigUnseeded -> Nothing
  ConfigInForce config -> Just config

-- | A proposed config generation. The seed carries @Nothing@ for its expected
-- prior; a CAS update carries @Just@ the generation it expects to be in force.
data ConfigProposal = ConfigProposal
  { proposalExpectedPrior :: !(Maybe ConfigGeneration)
  , proposalSchema :: !ConfigSchemaVersion
  , proposalDigest :: !ConfigDigest
  , proposalReference :: !ConfigReference
  }
  deriving (Eq, Show)

-- | Whether this authority build validates the proposal's schema version.
data SchemaValidity
  = SchemaSupported
  | SchemaUnsupported
  deriving (Eq, Show)

data ConfigProposeRefusal
  = -- | The proposal's schema version is not supported by this authority build.
    ConfigSchemaUnsupported
  | -- | A CAS update was attempted before the config was seeded.
    ConfigNotSeeded
  | -- | A re-seed was attempted after the config was already seeded.
    ConfigAlreadySeeded
  | -- | The expected prior generation does not match the in-force generation.
    ConfigCasConflict
  deriving (Eq, Show)

data ConfigProposeDecision
  = -- | The first seed from the Tier-0 boot projection (generation 1).
    ConfigSeeded !InForceConfig
  | -- | A CAS-advanced new generation.
    ConfigProposed !InForceConfig
  | -- | The proposed schema+digest is already in force (idempotent response-loss).
    ConfigProposeNoop !InForceConfig
  | ConfigProposeRefused !ConfigProposeRefusal
  deriving (Eq, Show)

-- | Decide a config proposal. Pure; never mutates state. An unsupported schema is
-- always refused. From unseeded, only a seed (no expected prior) is legal; a CAS
-- update is refused. From in-force, a re-seed is refused; a proposal matching the
-- in-force schema+digest is an idempotent no-op; a mismatched expected prior is a
-- CAS conflict; a matching expected prior advances the generation by one.
decideConfigPropose :: SchemaValidity -> ConfigState -> ConfigProposal -> ConfigProposeDecision
decideConfigPropose validity state proposal = case validity of
  SchemaUnsupported -> ConfigProposeRefused ConfigSchemaUnsupported
  SchemaSupported -> case state of
    ConfigUnseeded -> case proposalExpectedPrior proposal of
      Nothing -> ConfigSeeded (mkInForce (ConfigGeneration 1) proposal)
      Just _ -> ConfigProposeRefused ConfigNotSeeded
    ConfigInForce current -> case proposalExpectedPrior proposal of
      Nothing -> ConfigProposeRefused ConfigAlreadySeeded
      Just expected
        | proposalDigest proposal == inForceDigest current
            && proposalSchema proposal == inForceSchema current ->
            ConfigProposeNoop current
        | expected /= inForceGeneration current -> ConfigProposeRefused ConfigCasConflict
        | otherwise -> ConfigProposed (mkInForce (nextGeneration (inForceGeneration current)) proposal)
 where
  mkInForce generation p =
    InForceConfig generation (proposalSchema p) (proposalDigest p) (proposalReference p)
  nextGeneration (ConfigGeneration n) = ConfigGeneration (n + 1)

-- | Fold a config decision into the state. Only a seed or a CAS advance changes
-- the in-force generation; a no-op or refusal leaves it unchanged.
applyConfigPropose :: ConfigProposeDecision -> ConfigState -> ConfigState
applyConfigPropose decision state = case decision of
  ConfigSeeded config -> ConfigInForce config
  ConfigProposed config -> ConfigInForce config
  ConfigProposeNoop _ -> state
  ConfigProposeRefused _ -> state

-- | 'decideConfigPropose' then apply, returning the decision and evolved state.
stepConfigPropose
  :: SchemaValidity
  -> ConfigState
  -> ConfigProposal
  -> (ConfigProposeDecision, ConfigState)
stepConfigPropose validity state proposal =
  let decision = decideConfigPropose validity state proposal
   in (decision, applyConfigPropose decision state)
