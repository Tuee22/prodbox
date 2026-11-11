{-# LANGUAGE ImportQualifiedPost #-}

-- | Storage for a fully evaluated closed-data expression decoded by the pinned
-- Dhall implementation on the supported unprofiled 64-bit runtime. This is one
-- structural term, not decoder peak, process RSS, heap admission or allocation.
module Prodbox.Capacity.CanonicalDhallNormalForm
  ( CanonicalDhallNormalForm
  , canonicalDhallNormalForm
  , canonicalDhallTypeNormalForm
  , canonicalDhallBoundNormalForm
  , canonicalDhallExpressionBytes
  , canonicalDhallSequenceBytes
  , canonicalDhallMapBytes
  , canonicalDhallScalarBytes
  , canonicalDhallNormalFormBytes
  ) where

import Numeric.Natural (Natural)
import Prodbox.Config.CanonicalDhallValueShape

data CanonicalDhallNormalForm = NormalForm
  { storedExpressionBytes :: !Natural
  , storedSequenceBytes :: !Natural
  , storedMapBytes :: !Natural
  , storedScalarBytes :: !Natural
  }
  deriving (Eq, Show)

-- Each checker visit produces at most three Expr nodes. Sixteen words cover
-- those nodes plus its fixed Chunks/Maybe/FieldSelection/Map/Keys wrappers and
-- primitive boxed payloads. List element trees and map entries are separate.
-- Empty-list App List and the None/union selectors are included in this bound.
--
-- A finger tree node/digit/deep has at most five words. Deep contributes at
-- most fifteen words plus m five-word Nodes and a smaller tree, where the
-- original element count n >= 2 + 2*m. Induction gives F(n) <= 16*(n+1).
-- There are at most as many sequence roots as checked value/type visits.
--
-- Each map entry uses six Bin words, three original-key-list words and at
-- most five RecordField or two Just words. Sixteen covers those entry terms;
-- Map/Original wrappers are in the expression term. Sharing only reduces use.
--
-- Each valid UTF8 token copies its exact bytes (text-2.0.2's accepted path).
-- Ten words cover Text/array headers and alignment. Eight words cover a
-- Natural/Integer's boxed scalar, bignum header and alignment. Encoded spans
-- conservatively include both payload and CBOR headers. These are retained
-- normal-form terms; parsing, extraction, normalization and GC remain separate.
canonicalDhallNormalForm :: CanonicalDhallValueUsage -> CanonicalDhallNormalForm
canonicalDhallNormalForm usage =
  normalFormParts
    (canonicalDhallValueVisits usage + canonicalDhallTypeVisits usage)
    (canonicalDhallListElements usage)
    (canonicalDhallRecordFields usage + canonicalDhallUnionAlternatives usage)
    (canonicalDhallTextTokens usage)
    (canonicalDhallIntegerTokens usage)
    (canonicalDhallTextTokenBytes usage + canonicalDhallIntegerTokenBytes usage)

-- Only the exact type subtrees carried by None, empty lists and union
-- selectors. Value scalars and value-record keys do not enlarge this term.
-- The same structural layout bound applies, conservatively including sequence
-- roots for every type visit. Compact trusted expected-schema labels can use
-- this shape-matched data bound; their construction is a separate obligation.
canonicalDhallTypeNormalForm :: CanonicalDhallValueUsage -> CanonicalDhallNormalForm
canonicalDhallTypeNormalForm usage =
  normalFormParts
    (canonicalDhallTypeVisits usage)
    0
    (canonicalDhallTypeRecordFields usage + canonicalDhallTypeUnionAlternatives usage)
    (canonicalDhallTypeTextTokens usage)
    0
    (canonicalDhallTypeTextTokenBytes usage)

-- The checker consumes each scalar token once; their encoded spans are
-- disjoint and sum to at most the supplied input ceiling. This is prospective
-- fully evaluated syntax storage only. The caller must enforce that ceiling;
-- decoder construction, typed extraction, producers, GC and other roots are
-- separate costs, and this metadata grants no runtime/Authority admission.
canonicalDhallBoundNormalForm :: Natural -> CanonicalDhallValueBound -> CanonicalDhallNormalForm
canonicalDhallBoundNormalForm inputCeiling bound =
  normalFormParts
    (canonicalDhallBoundValueVisits bound + canonicalDhallBoundTypeVisits bound)
    (canonicalDhallBoundListElements bound)
    (canonicalDhallBoundRecordFields bound + canonicalDhallBoundUnionAlternatives bound)
    (canonicalDhallBoundTextTokens bound)
    (canonicalDhallBoundIntegerTokens bound)
    inputCeiling

normalFormParts
  :: Natural -> Natural -> Natural -> Natural -> Natural -> Natural -> CanonicalDhallNormalForm
normalFormParts visits elements fields texts integers payloadBytes =
  NormalForm
    (8 * 16 * (visits + 1))
    (8 * 16 * (elements + visits))
    (8 * 16 * fields)
    (8 * (10 * texts + 8 * integers) + payloadBytes)

canonicalDhallExpressionBytes
  , canonicalDhallSequenceBytes
  , canonicalDhallMapBytes
  , canonicalDhallScalarBytes
    :: CanonicalDhallNormalForm -> Natural
canonicalDhallExpressionBytes = storedExpressionBytes
canonicalDhallSequenceBytes = storedSequenceBytes
canonicalDhallMapBytes = storedMapBytes
canonicalDhallScalarBytes = storedScalarBytes

canonicalDhallNormalFormBytes :: CanonicalDhallNormalForm -> Natural
canonicalDhallNormalFormBytes (NormalForm expression sequenceBytes fields scalar) =
  expression + sequenceBytes + fields + scalar
