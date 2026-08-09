-- | Constructor-bearing internal module for 'RoundTripWitness'.
--
-- A round-trip witness is the one value on the readiness path that claims
-- something a read cannot establish: that a conditional __write__ reached the
-- store and the store accepted it.
-- [bootstrap_readiness_doctrine.md § 2.3](../../../../documents/engineering/bootstrap_readiness_doctrine.md)
-- permits an object GET to prove only a read capability, so evidence of a write
-- must come from the interpreter that performed one — never from a caller that
-- decided it had happened.
--
-- This module exists to give that constructor a module boundary rather than an
-- export-list comment. Its importers are an allowlist enforced mechanically by
-- @prodbox dev check@, and every entry is a place that actually performed or
-- authoritatively decoded a round trip:
--
--   * the object-store conditional-write interpreters, which hold the version
--     the store returned for the write they just issued;
--   * the gateway state decoder, which reads the receipt the daemon recorded at
--     the instant its own conditional write landed.
--
-- Do not add a second kind of importer. Every additional one is a place the
-- evidence can be fabricated, which is exactly how the superseded implementation
-- came to satisfy a write-shaped requirement with a string literal.
--
-- Note the bound this does /not/ deliver, per
-- [chaos_hardening_doctrine.md § 22](../../../../documents/engineering/chaos_hardening_doctrine.md):
-- it constrains what a process can construct, not how old the constructed value
-- may be by the time it is consumed. That is what 'roundTripWitnessLandedAt' and
-- the freshness window are for — the witness carries the instant the write
-- landed precisely so the staleness bound has a real instant to bound.
module Prodbox.ControlPlane.Observation.Internal
  ( RoundTripWitness (..)
  , mintRoundTripWitness
  )
where

import Prodbox.Lifecycle.CheckpointAuthority (ModelBObjectVersion)
import Prodbox.Lifecycle.Lease (AuthorityTime)

-- | Proof that a write/CAS round trip actually reached the store: the version
-- the store returned for that write, and the instant the write landed.
--
-- The instant is stamped by the interpreter that performed the operation, not
-- read from a clock afterwards by whoever is folding the evidence. Without that
-- the freshness window is inert: it bounds the age of the observation rather
-- than the age of the write the observation claims.
data RoundTripWitness = MkRoundTripWitness
  { internalRoundTripVersion :: !ModelBObjectVersion
  , internalRoundTripLandedAt :: !AuthorityTime
  }
  deriving (Eq, Show)

-- | Mint a witness from a version a store returned and the instant that write
-- landed. Total: both arguments are already smart-constructed values, so there
-- is no failure mode left to report here — the validation lives in
-- 'Prodbox.Lifecycle.CheckpointAuthority.mkModelBObjectVersion', which rejects
-- an empty or control-bearing version, so a store that reports no version
-- cannot be turned into a witness at all.
mintRoundTripWitness :: ModelBObjectVersion -> AuthorityTime -> RoundTripWitness
mintRoundTripWitness = MkRoundTripWitness
