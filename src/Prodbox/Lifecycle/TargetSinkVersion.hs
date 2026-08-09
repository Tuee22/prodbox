-- | The target-sink expected-version token, abstract to every consumer.
--
-- This is the public face of "Prodbox.Lifecycle.TargetSinkVersion.Internal".
-- It exports the type without its constructor and the projection into the
-- store's numbering, so a 'TargetSinkVersion' can be compared, rendered, and
-- handed to a conditional write, but not authored.  The one module permitted
-- to mint one is the Vault observation decoder, which imports the internal
-- module directly under a @prodbox dev check@ allowlist.
module Prodbox.Lifecycle.TargetSinkVersion
  ( TargetSinkVersion
  , targetSinkVersionValue
  )
where

import Numeric.Natural (Natural)
import Prodbox.Lifecycle.TargetSinkVersion.Internal
  ( TargetSinkVersion (..)
  )

-- | The store version this token stands for.
targetSinkVersionValue :: TargetSinkVersion -> Natural
targetSinkVersionValue = internalTargetSinkVersionValue
