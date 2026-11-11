{-# LANGUAGE ImportQualifiedPost #-}

-- | Bind a trusted closed shape's measurement to the exact immutable bytes
-- subsequently decoded. This uses the pinned direct Expr decoder once; no
-- version-wrapper fallback runs after the closed producer shape was checked.
-- Successful results contain fully evaluated syntax; decoder closures cannot
-- escape into the subsequent typed extraction phase.
-- Backing origin, schema storage, construction/extraction/validation/GC peaks
-- and the enclosing original operation remain separately funded and admitted.
module Prodbox.Config.CheckedCanonicalDhallData
  ( CheckedCanonicalDhallData
  , inspectCanonicalDhallData
  , checkedCanonicalDhallDataUsage
  , decodeCheckedCanonicalDhallData
  ) where

import Codec.CBOR.Read qualified as Cbor
import Codec.Serialise (decode)
import Control.DeepSeq (deepseq)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.Void (Void)
import Dhall.Binary ()
import Dhall.Core qualified as Core
import Prodbox.Config.CanonicalDhallValueShape

-- No constructor, Show or serialization can detach the measurement from its
-- source. This owns a reference, not a compact-backing or admission witness.
data CheckedCanonicalDhallData = Checked !ByteString !CanonicalDhallValueUsage

inspectCanonicalDhallData
  :: CanonicalDhallValueShape
  -> ByteString
  -> Either CanonicalDhallValueShapeError CheckedCanonicalDhallData
inspectCanonicalDhallData shape bytes = Checked bytes <$> measureCanonicalDhallValueShape shape bytes

checkedCanonicalDhallDataUsage :: CheckedCanonicalDhallData -> CanonicalDhallValueUsage
checkedCanonicalDhallDataUsage (Checked _ usage) = usage

decodeCheckedCanonicalDhallData
  :: CheckedCanonicalDhallData
  -> Either CanonicalDhallValueShapeError (Core.Expr Void Void)
decodeCheckedCanonicalDhallData (Checked bytes _) = do
  (remaining, expression) <-
    first
      (const CanonicalDhallValueEncodingInvalid)
      (Cbor.deserialiseFromBytes decode (Lazy.fromStrict bytes))
  if Lazy.null remaining
    then expression `deepseq` Right expression
    else Left CanonicalDhallValueEncodingInvalid
