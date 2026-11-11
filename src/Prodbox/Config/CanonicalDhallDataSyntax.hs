{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- | Explicit evaluated SDK syntax stages. These are not normalizers, admission
-- receipts or complete construction/GC/working-set certificates.
module Prodbox.Config.CanonicalDhallDataSyntax
  ( EmbeddedCanonicalDhallData
  , CanonicalDhallDataSyntax
  , embedCanonicalDhallData
  , embedCanonicalDhallDataWith
  , eraseCanonicalDhallDataSource
  , canonicalDhallDataSyntaxExpression
  , canonicalDhallProducerSyntaxDataBytes
  ) where

import Control.DeepSeq (force)
import Data.Void (Void)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Src (Src)
import Numeric.Natural (Natural)
import Prodbox.Capacity.CanonicalDhallNormalForm
import Prodbox.Config.CanonicalDhallValueShape (CanonicalDhallValueUsage)

data EmbeddedCanonicalDhallData = Embedded !(Core.Expr Src Void)
data CanonicalDhallDataSyntax = Syntax !(Core.Expr Void Void)

embedCanonicalDhallData :: (Dhall.ToDhall value) => value -> EmbeddedCanonicalDhallData
embedCanonicalDhallData = embedCanonicalDhallDataWith Dhall.inject

embedCanonicalDhallDataWith :: Dhall.Encoder value -> value -> EmbeddedCanonicalDhallData
embedCanonicalDhallDataWith encoder value =
  let !expression = force (Dhall.embed encoder value)
   in Embedded expression

eraseCanonicalDhallDataSource :: EmbeddedCanonicalDhallData -> CanonicalDhallDataSyntax
eraseCanonicalDhallDataSource (Embedded expression) =
  let !erased = force (Core.denote expression)
   in Syntax erased

canonicalDhallDataSyntaxExpression :: CanonicalDhallDataSyntax -> Core.Expr Void Void
canonicalDhallDataSyntaxExpression (Syntax expression) = expression

-- This prospective term is restricted to the selected closed SettingsEnvelope
-- encoders/decoders and their checked source shape. Generic injection preserves
-- constructor counts, closed types and arbitrary-width Naturals. Returned AWS
-- normalized ASCII Text does not grow its source span; other Text is shared.
-- Generic field labels are exact shrunk Text.pack arrays on text-2.0.2. Their
-- selected embeddings introduce no source annotations. The supported total
-- denote walk preserves that closed-data shape while erasing annotation slots.
-- Each full tree therefore fits the existing structural term. Charge both
-- complete trees plus their two wrappers, even when the execution shares leaves.
-- Generic product/map and sequence construction, compiler closures, traversal
-- stacks, dictionaries, dead allocation, GC and the rest of the program remain
-- separate. This bound does not apply to an arbitrary custom ToDhall instance.
canonicalDhallProducerSyntaxDataBytes :: CanonicalDhallValueUsage -> Natural
canonicalDhallProducerSyntaxDataBytes usage =
  32 + 2 * canonicalDhallNormalFormBytes (canonicalDhallNormalForm usage)
