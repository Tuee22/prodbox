-- | Constructor-bearing internal module for 'TargetSinkVersion'.
--
-- Vault KV v2 checks exactly one token when it accepts a conditional write:
-- the @options.cas@ expected version.  Every other field a target record
-- carries -- owner nonce, fencing token, credential generation, value digest
-- -- is opaque data the store never inspects.  The expected version is
-- therefore the only value on this path for which
-- [chaos_hardening_doctrine.md § 21](../../../../documents/engineering/chaos_hardening_doctrine.md)
-- row C is literally implementable, and it must not be authorable by a
-- caller that never read the store.
--
-- This module exists to give that constructor a module boundary rather than
-- an export-list comment.  It is imported by exactly one module -- the target
-- sink's Vault observation decoder -- and that sole-importer property is
-- enforced mechanically by @prodbox dev check@.  Do not add a second
-- importer: a 'TargetSinkVersion' is meant to be evidence that a store read
-- happened, and every additional importer is a place that evidence can be
-- fabricated.
--
-- Note the bound this does /not/ deliver, per
-- [§ 22](../../../../documents/engineering/chaos_hardening_doctrine.md): it
-- constrains what a process can construct, not what two processes can do
-- concurrently.  Two writers each holding a validly-decoded version both
-- produce legal requests, and Vault's version compare only makes the loser
-- fail after the winner has landed.
module Prodbox.Lifecycle.TargetSinkVersion.Internal
  ( TargetSinkVersion (..)
  , targetSinkVersionFromStoreVersion
  )
where

import Numeric.Natural (Natural)

-- | An expected version for a target-sink conditional write, in the store's
-- own numbering.  Held as the numeric version rather than its rendering so
-- that ordering is numeric and no parse step stands between the observation
-- and the write.
newtype TargetSinkVersion = TargetSinkVersion
  { internalTargetSinkVersionValue :: Natural
  }
  deriving (Eq, Ord, Show)

-- | Mint an expected version from a version number a store reported.
--
-- Rejects zero, which Vault KV v2 never assigns to an existing secret: a
-- zero here means the read did not observe a live version, and admitting it
-- would let an initialize-shaped write be issued as a replace.
targetSinkVersionFromStoreVersion :: Natural -> Maybe TargetSinkVersion
targetSinkVersionFromStoreVersion value
  | value == 0 = Nothing
  | otherwise = Just (TargetSinkVersion value)
