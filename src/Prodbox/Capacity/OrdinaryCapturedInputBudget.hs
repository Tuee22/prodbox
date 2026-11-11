{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TemplateHaskell #-}

-- | A necessary captured-input scratch floor, not a complete decoder/program
-- working-set proof. Parser, extraction, canonical producer, validation, GC,
-- other retained state, native and runtime filesystem terms remain independent.
module Prodbox.Capacity.OrdinaryCapturedInputBudget
  ( OrdinaryCapturedInputBudget
  , OrdinaryCapturedInputBudgetError (..)
  , ordinaryCapturedInputBudget
  , ordinaryCapturedInitialProfileDataFloor
  , ordinaryCapturedFixedMetadataDataBytes
  , ordinaryCapturedSourceBytes
  , ordinaryCapturedSourcePayloadBytes
  , ordinaryCapturedSettingsNormalFormBytes
  , ordinaryCapturedSettingsExtractedDataBytes
  , ordinaryCapturedSettingsExtractionSequenceDataBytes
  , ordinaryCapturedSettingsGenericProductDataBytes
  , ordinaryCapturedSettingsGenericSumDataBytes
  , ordinaryCapturedSettingsTypeTreeDataBytes
  , ordinaryCapturedSettingsTypeMapDataBytes
  , ordinaryCapturedSettingsAwsCaseArrayDataBytes
  , ordinaryCapturedSettingsEncodingProgramBytes
  , ordinaryCapturedSettingsProducerSyntaxDataBytes
  , ordinaryCapturedSettingsEncodingBufferBytes
  , ordinaryCapturedSettingsPathConversionBytes
  , ordinaryCapturedSettingsMapPairBytes
  , ordinaryCapturedSettingsMapKeyProjectionBytes
  , ordinaryCapturedSettingsMapSeenSetBytes
  , ordinaryCapturedSettingsMapSeenSetAllocationBytes
  , ordinaryCapturedSettingsMapConstructionDataBytes
  , ordinaryCapturedSettingsMapDecodeDataBytes
  , ordinaryCapturedProfileNormalFormBytes
  , ordinaryCapturedProfileReaderStepDataBytes
  , ordinaryCapturedInitialProfileDataBytes
  , ordinaryCapturedProfileScalarImportBytes
  , ordinaryCapturedProfileScalarHandoffDataBytes
  , ordinaryCapturedProfileEncodingBufferBytes
  , ordinaryCapturedProfileEncodingProgramBytes
  , ordinaryCapturedRequestPayloadCopyBytes
  , ordinaryCapturedMinimumScratchBytes
  , ordinaryCapturedInputBudgetNormalFormBytes
  , checkOrdinaryCapturedInputScratch
  , ordinaryCapturedPathConversionBytes
  , ordinaryCapturedMapPairBytes
  , ordinaryCapturedMapKeyProjectionBytes
  , ordinaryCapturedMapSeenSetBytes
  , ordinaryCapturedMapSeenSetAllocationBytes
  , ordinaryCapturedMapConstructionDataBytes
  , ordinaryCapturedMapDecodeDataBytes
  , ordinaryCapturedPathMinimumStateBytes
  , checkOrdinaryCapturedPathState
  , checkOrdinaryCapturedWireStringState
  , checkOrdinaryCapturedWireStringLength
  , ordinaryCapturedWireStringDataBytes
  ) where

import Language.Haskell.TH.Syntax
  ( Exp (LitE)
  , Lit (IntegerL)
  , addDependentFile
  , loc_filename
  , location
  , runIO
  )
import Numeric.Natural (Natural)
import Prodbox.Capacity.BoxedNormalForm (boxedCharBytes, boxedNaturalBytes, boxedRecordBytes)
import Prodbox.Capacity.CanonicalDhallNormalForm
import Prodbox.Capacity.ProfileScalarHandoffData (profileScalarHandoffDataBytes)
import Prodbox.Capacity.SettingsExtractedData
  ( settingsExtractionAwsCaseArrayDataBytes
  , settingsExtractionSequenceDataBytes
  , settingsExtractionTypeMapDataBytes
  , settingsExtractionTypeTreeDataBytes
  )
import Prodbox.Config.CanonicalDhallDataEncoding
  ( settingsCanonicalOutputBufferBytes
  , settingsCanonicalProgramBytes
  )
import Prodbox.Config.CanonicalDhallDataSyntax (canonicalDhallProducerSyntaxDataBytes)
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.FieldNameTables (fieldNameTablesDataBytes)
import Prodbox.Config.OrdinaryMemoryProfile
  ( ordinaryMemoryProfileEncodingBufferBytes
  , ordinaryMemoryProfileEncodingPlanBound
  , ordinaryMemoryProfileMaximumBytes
  , ordinaryMemoryProfileNormalFormBound
  , ordinaryMemoryProfileReaderStepDataBytes
  , ordinaryMemoryProfileScalarValueBytes
  )
import Prodbox.Config.OrdinaryMemoryProfile.DeclaredShape (ordinaryMemoryProfileShapeDataBytes)
import Prodbox.Config.SchemaSourceDependencies (discoverSchemaSourceDependencies)
import Prodbox.ControlPlane.OrdinaryWireProfile (ordinaryInitialProfileDataBytes)
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
  ( rpcBirthSettingsExtractedDataBytes
  , rpcBirthSettingsGenericProductDataBytes
  , rpcBirthSettingsGenericSumDataBytes
  , rpcBirthSettingsShapeDataBytes
  )

data OrdinaryCapturedInputBudget = InputBudget
  { storedSourceBytes :: !Natural
  , storedSourcePayloadBytes :: !Natural
  , storedSettingsNormalFormBytes :: !Natural
  , storedSettingsExtractedDataBytes :: !Natural
  , storedSettingsExtractionSequenceDataBytes :: !Natural
  , storedSettingsGenericProductDataBytes :: !Natural
  , storedSettingsGenericSumDataBytes :: !Natural
  , storedSettingsTypeTreeDataBytes :: !Natural
  , storedSettingsTypeMapDataBytes :: !Natural
  , storedSettingsAwsCaseArrayDataBytes :: !Natural
  , storedSettingsProducerSyntaxDataBytes :: !Natural
  , storedSettingsEncodingProgramBytes :: !Natural
  , storedSettingsEncodingBufferBytes :: !Natural
  , storedSettingsPathConversionBytes :: !Natural
  , storedSettingsMapPairBytes :: !Natural
  , storedSettingsMapKeyProjectionBytes :: !Natural
  , storedSettingsMapSeenSetBytes :: !Natural
  , storedSettingsMapSeenSetAllocationBytes :: !Natural
  , storedSettingsMapConstructionDataBytes :: !Natural
  , storedInitialProfileDataBytes :: !Natural
  , storedProfileReaderStepDataBytes :: !Natural
  , storedProfileNormalFormBytes :: !Natural
  , storedProfileScalarHandoffDataBytes :: !Natural
  , storedProfileScalarImportBytes :: !Natural
  , storedProfileEncodingBufferBytes :: !Natural
  , storedProfileEncodingProgramBytes :: !Natural
  , storedRequestPayloadCopyBytes :: !Natural
  }
  deriving (Eq, Show)

data OrdinaryCapturedInputBudgetError
  = OrdinaryCapturedInputScratchUnderfunded !Natural !Natural
  | OrdinaryCapturedPathStateUnderfunded !Natural !Natural
  | OrdinaryCapturedWireStringStateUnderfunded !Natural !Natural
  deriving (Eq, Show)

-- The closed loader holds the two captured source buffers while settings and
-- the strict embedded profile are decoded serially. Request payload copies join
-- the latter phase. The profile term bounds its returned typed value; the
-- direct profile codec constructs no expression tree. It never adds the two
-- phases as if both ran concurrently. Runtime command buffers
-- retain their separate existing reserve and are not included here.
-- Before profile parsing, the cold loader requires the complete existing
-- 64-KiB profile domain's known data phase, alongside both originating buffers.
-- It does not borrow an unparsed profile's declared scratch. This is a deny-only
-- data floor: outer wire/shape/compiler/control/stack/GC/native construction
-- and other roots remain independent, and no admission receipt is returned.
ordinaryCapturedInitialProfileDataFloor :: Natural -> Natural -> Natural
ordinaryCapturedInitialProfileDataFloor commandBytes settingsBytes =
  ordinaryCapturedFixedMetadataDataBytes
    + compactBufferBytes commandBytes
    + compactBufferBytes settingsBytes
    + ordinaryInitialProfileDataBytes maximumProfile
    + ordinaryMemoryProfileNormalFormBound maximumProfile
    + ordinaryMemoryProfileReaderStepDataBytes
    + max
      (ordinaryMemoryProfileScalarValueBytes maximumProfile + profileScalarHandoffDataBytes)
      ( ordinaryMemoryProfileEncodingPlanBound maximumProfile
          + 64
          + 8 * ((ordinaryMemoryProfileEncodingBufferBytes maximumProfile + 7) `div` 8)
      )
 where
  maximumProfile = fromIntegral ordinaryMemoryProfileMaximumBytes

-- Both shape templates and all four NOINLINE field tables remain charged
-- across both input branches. The fixed sum is emitted at build time; retain
-- the predecessor's128-byte scalar reserve conservatively. Table lookup,
-- dictionaries/control/update/GC/native costs and admission remain separate.
{-# NOINLINE ordinaryCapturedFixedMetadataDataBytes #-}
ordinaryCapturedFixedMetadataDataBytes :: Natural
ordinaryCapturedFixedMetadataDataBytes =
  $( do
       here <- location
       observed <- runIO (discoverSchemaSourceDependencies (loc_filename here))
       sources <- either (fail . show) pure observed
       mapM_ addDependentFile sources
       let total =
             rpcBirthSettingsShapeDataBytes
               + ordinaryMemoryProfileShapeDataBytes
               + fieldNameTablesDataBytes
               + 128
       if total <= fromIntegral (maxBound :: Int)
         then pure (LitE (IntegerL (toInteger total)))
         else fail "fixed input metadata exceeds the pinned address space"
   )

ordinaryCapturedInputBudget
  :: Natural
  -> CanonicalDhallValueUsage
  -> CanonicalDhallValueUsage
  -> OrdinaryCapturedInputBudget
ordinaryCapturedInputBudget commandBytes settings profile =
  InputBudget
    (compactBufferBytes commandBytes + compactBufferBytes (canonicalDhallInputBytes settings))
    (commandBytes + canonicalDhallInputBytes settings)
    (canonicalDhallNormalFormBytes (canonicalDhallNormalForm settings))
    (rpcBirthSettingsExtractedDataBytes settings)
    (settingsExtractionSequenceDataBytes settings)
    (rpcBirthSettingsGenericProductDataBytes settings)
    (rpcBirthSettingsGenericSumDataBytes settings)
    (settingsExtractionTypeTreeDataBytes settings)
    (settingsExtractionTypeMapDataBytes settings)
    (settingsExtractionAwsCaseArrayDataBytes settings)
    (canonicalDhallProducerSyntaxDataBytes settings)
    (settingsCanonicalProgramBytes settings)
    (settingsCanonicalOutputBufferBytes settings)
    (ordinaryCapturedPathConversionBytes settings)
    (ordinaryCapturedMapPairBytes settings)
    (ordinaryCapturedMapKeyProjectionBytes settings)
    (ordinaryCapturedMapSeenSetBytes settings)
    (ordinaryCapturedMapSeenSetAllocationBytes settings)
    (ordinaryCapturedMapConstructionDataBytes settings)
    (ordinaryInitialProfileDataBytes (fromIntegral ordinaryMemoryProfileMaximumBytes))
    ordinaryMemoryProfileReaderStepDataBytes
    (ordinaryMemoryProfileNormalFormBound (canonicalDhallInputBytes profile))
    -- Conservatively hold the complete prospective typed profile alongside
    -- one importing scalar, even though that scalar can be part of the profile.
    profileScalarHandoffDataBytes
    (ordinaryMemoryProfileScalarValueBytes (canonicalDhallInputBytes profile))
    -- The one canonical readback buffer owns a PlainPtr allocation with nine
    -- writer lookahead bytes. BS/ForeignPtr/array headers and alignment use
    -- the pinned compact-byte layout; source and decoded data remain live.
    (64 + 8 * ((ordinaryMemoryProfileEncodingBufferBytes (canonicalDhallInputBytes profile) + 7) `div` 8))
    (ordinaryMemoryProfileEncodingPlanBound (canonicalDhallInputBytes profile))
    commandBytes

-- These two buffers come from HostControllerInputs.readHeldInput, whose
-- create call allocates each held stat size exactly once. On the pinned ABI,
-- BS/PlainPtr/array headers total 64 bytes and each payload rounds to a word.
-- References from cursors and decoder views share these originating buffers.
-- This requires that established compact origin; arbitrary views do not earn
-- an ownership witness from a length. File/stat/descriptor/control objects and
-- the outer paired-input wrapper retain their separate state/phase terms.
compactBufferBytes :: Natural -> Natural
compactBufferBytes payload = 64 + 8 * ((payload + 7) `div` 8)

ordinaryCapturedSourceBytes
  , ordinaryCapturedSourcePayloadBytes
  , ordinaryCapturedSettingsNormalFormBytes
  , ordinaryCapturedSettingsExtractedDataBytes
  , ordinaryCapturedSettingsExtractionSequenceDataBytes
  , ordinaryCapturedSettingsGenericProductDataBytes
  , ordinaryCapturedSettingsGenericSumDataBytes
  , ordinaryCapturedSettingsTypeTreeDataBytes
  , ordinaryCapturedSettingsTypeMapDataBytes
  , ordinaryCapturedSettingsAwsCaseArrayDataBytes
  , ordinaryCapturedSettingsEncodingProgramBytes
  , ordinaryCapturedSettingsProducerSyntaxDataBytes
  , ordinaryCapturedSettingsEncodingBufferBytes
  , ordinaryCapturedSettingsPathConversionBytes
  , ordinaryCapturedSettingsMapPairBytes
  , ordinaryCapturedSettingsMapKeyProjectionBytes
  , ordinaryCapturedSettingsMapSeenSetBytes
  , ordinaryCapturedSettingsMapSeenSetAllocationBytes
  , ordinaryCapturedSettingsMapConstructionDataBytes
  , ordinaryCapturedSettingsMapDecodeDataBytes
  , ordinaryCapturedProfileNormalFormBytes
  , ordinaryCapturedProfileReaderStepDataBytes
  , ordinaryCapturedProfileScalarImportBytes
  , ordinaryCapturedProfileScalarHandoffDataBytes
  , ordinaryCapturedProfileEncodingBufferBytes
  , ordinaryCapturedProfileEncodingProgramBytes
  , ordinaryCapturedRequestPayloadCopyBytes
    :: OrdinaryCapturedInputBudget -> Natural
ordinaryCapturedSourceBytes = storedSourceBytes
ordinaryCapturedSourcePayloadBytes = storedSourcePayloadBytes
ordinaryCapturedSettingsNormalFormBytes = storedSettingsNormalFormBytes
ordinaryCapturedSettingsExtractedDataBytes = storedSettingsExtractedDataBytes
ordinaryCapturedSettingsExtractionSequenceDataBytes = storedSettingsExtractionSequenceDataBytes
ordinaryCapturedSettingsGenericProductDataBytes = storedSettingsGenericProductDataBytes
ordinaryCapturedSettingsGenericSumDataBytes = storedSettingsGenericSumDataBytes
ordinaryCapturedSettingsTypeTreeDataBytes = storedSettingsTypeTreeDataBytes
ordinaryCapturedSettingsTypeMapDataBytes = storedSettingsTypeMapDataBytes
ordinaryCapturedSettingsAwsCaseArrayDataBytes = storedSettingsAwsCaseArrayDataBytes
ordinaryCapturedSettingsProducerSyntaxDataBytes = storedSettingsProducerSyntaxDataBytes
ordinaryCapturedSettingsEncodingProgramBytes = storedSettingsEncodingProgramBytes
ordinaryCapturedSettingsEncodingBufferBytes = storedSettingsEncodingBufferBytes
ordinaryCapturedSettingsPathConversionBytes = storedSettingsPathConversionBytes
ordinaryCapturedSettingsMapPairBytes = storedSettingsMapPairBytes
ordinaryCapturedSettingsMapKeyProjectionBytes = storedSettingsMapKeyProjectionBytes
ordinaryCapturedSettingsMapSeenSetBytes = storedSettingsMapSeenSetBytes
ordinaryCapturedSettingsMapSeenSetAllocationBytes = storedSettingsMapSeenSetAllocationBytes
ordinaryCapturedSettingsMapConstructionDataBytes = storedSettingsMapConstructionDataBytes
ordinaryCapturedSettingsMapDecodeDataBytes budget =
  storedSettingsMapPairBytes budget
    + storedSettingsMapKeyProjectionBytes budget
    + storedSettingsMapSeenSetBytes budget
    + storedSettingsMapSeenSetAllocationBytes budget
    + storedSettingsMapConstructionDataBytes budget
ordinaryCapturedInitialProfileDataBytes :: OrdinaryCapturedInputBudget -> Natural
ordinaryCapturedInitialProfileDataBytes = storedInitialProfileDataBytes
ordinaryCapturedProfileReaderStepDataBytes = storedProfileReaderStepDataBytes
ordinaryCapturedProfileNormalFormBytes = storedProfileNormalFormBytes
ordinaryCapturedProfileScalarHandoffDataBytes = storedProfileScalarHandoffDataBytes
ordinaryCapturedProfileScalarImportBytes = storedProfileScalarImportBytes
ordinaryCapturedProfileEncodingBufferBytes = storedProfileEncodingBufferBytes
ordinaryCapturedProfileEncodingProgramBytes = storedProfileEncodingProgramBytes
ordinaryCapturedRequestPayloadCopyBytes = storedRequestPayloadCopyBytes

ordinaryCapturedMinimumScratchBytes :: OrdinaryCapturedInputBudget -> Natural
-- The four compact request byte payloads coexist with the strict typed profile,
-- prepared encoding program and canonical readback buffer during typed request
-- decoding. Their payload copies total at most the held command length; headers
-- and the remaining typed request state retain separate terms.
-- Scalar import and canonical output are serial phases. The scalar term covers
-- positive numeric objects and the separately charged scalar handoff data;
-- the SDK/reader's control and other temporary
-- objects retain independent obligations. The output phase can dominate it.
-- This phase term does not claim disjoint retained application-state storage.
-- The SDK first decodes record/union pair lists, then fully evaluates the
-- expression before typed extraction starts. Map data and path String
-- conversion therefore join by max. Extracted typed data joins the latter
-- phase, beside a conservative complete syntax
-- term. The SDK's temporary extracted Seq spines also coexist with a
-- conservative complete raw-data term, Generic product/sum spines and every
-- prospective guarded AWS case-converter array, before path conversion/readback.
-- Expected-type metadata can remain reachable through SDK CAFs. Conservatively
--- retain the full selected type-tree/map terms beside both serial branches, through
-- profile and final-request checkpoints, rather than retiring it at extraction.
-- These three serial stages join by max. Both evaluated producer syntax trees
-- join the encoding phase.
-- Other construction/control/stack/GC costs remain separate.
ordinaryCapturedMinimumScratchBytes budget =
  ordinaryCapturedFixedMetadataDataBytes
    + storedSourceBytes budget
    + storedInitialProfileDataBytes budget
    + storedSettingsTypeTreeDataBytes budget
    + storedSettingsTypeMapDataBytes budget
    + max
      ( storedSettingsNormalFormBytes budget
          + max
            (ordinaryCapturedSettingsMapDecodeDataBytes budget)
            ( storedSettingsExtractedDataBytes budget
                + max
                  ( storedSettingsExtractionSequenceDataBytes budget
                      + storedSettingsGenericProductDataBytes budget
                      + storedSettingsGenericSumDataBytes budget
                      + storedSettingsAwsCaseArrayDataBytes budget
                  )
                  ( max
                      (storedSettingsPathConversionBytes budget)
                      ( storedSettingsProducerSyntaxDataBytes budget
                          + storedSettingsEncodingProgramBytes budget
                          + storedSettingsEncodingBufferBytes budget
                      )
                  )
            )
      )
      ( storedProfileReaderStepDataBytes budget
          + storedProfileNormalFormBytes budget
          + storedRequestPayloadCopyBytes budget
          + max
            (storedProfileScalarImportBytes budget + storedProfileScalarHandoffDataBytes budget)
            (storedProfileEncodingBufferBytes budget + storedProfileEncodingProgramBytes budget)
      )

checkOrdinaryCapturedInputScratch
  :: Natural -> OrdinaryCapturedInputBudget -> Either OrdinaryCapturedInputBudgetError ()
checkOrdinaryCapturedInputScratch available budget
  | available >= required = Right ()
  | otherwise = Left (OrdinaryCapturedInputScratchUnderfunded required available)
 where
  required = ordinaryCapturedMinimumScratchBytes budget

-- Dhall.Binary.replicateDecoder makes one cons and one key/value pair per
-- record field or union alternative before Dhall.Map.fromList consumes them.
-- Their headers use three words each on the pinned ABI. Keys, field wrappers
-- and values are shared with the expression term, so do not charge them again.
-- Reserve the shared two-word Nil once, including for empty maps. This bounds
-- this materialized data only; lazy map/control closures, key projection,
-- duplicate-removal Set construction and GC remain independent obligations.
ordinaryCapturedMapPairBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedMapPairBytes usage =
  16 + 48 * (canonicalDhallRecordFields usage + canonicalDhallUnionAlternatives usage)

-- Dhall.Map.fromList retains the pair list while separately projecting keys
-- with map fst for nubOrd. Charge a complete projection spine even when the
-- compiler fuses it. Its Text values alias syntax keys and its shared Nil is
-- already in the pair-list term. The final original-key spine is in syntax.
ordinaryCapturedMapKeyProjectionBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedMapKeyProjectionBytes usage =
  24 * (canonicalDhallRecordFields usage + canonicalDhallUnionAlternatives usage)

-- One settled nubOrd prefix Set per map has at most its field count in Bin
-- nodes. containers-0.6.8 uses five words per Bin and a shared two-word Tip.
-- Keys alias syntax. The allocation term below separately charges all Bin
-- construction, including replaced paths and rotations. Executable closures,
-- update frames, comparison and collection retain separate peak obligations.
ordinaryCapturedMapSeenSetBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedMapSeenSetBytes usage =
  16 + 40 * (canonicalDhallRecordFields usage + canonicalDhallUnionAlternatives usage)

-- Dhall.Map.nubOrd inserts at most once per checked field/alternative. In
-- containers-0.6.8, insert visits one path and balanceL/balanceR allocate at
-- most three five-word Bin nodes per visited ancestor, plus one leaf/replacement.
-- For n>=3 the valid delta=3 invariant bounds each child by floor(3*(n-1)/4).
-- The n<=2 base has height at most n. The shape measurement sums n*h(n)
-- under that recurrence for each map separately, without logarithmic rounding.
-- Charge every insertion's Bin allocation, including dead/replaced versions,
-- without relying on collection between insertions. This intentionally also
-- charges final nodes covered by the settled Set term. Key payloads alias
-- syntax; compiler/control/stack, other constructors and GC copies stay separate.
ordinaryCapturedMapSeenSetAllocationBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedMapSeenSetAllocationBytes usage =
  40 * (entries + 3 * canonicalDhallMapEntryHeightSum usage)
 where
  entries = canonicalDhallRecordFields usage + canonicalDhallUnionAlternatives usage

-- containers-0.6.8 Strict.Map.fromList consumes every entry through one
-- singleton, insert/insertMax, or link. For a map with n entries, height is
-- at most H=h(n), by the same delta=3 recurrence used for Set.
-- link descends its two input heights and any terminal insertion path;
-- together these visit at most 2*H ancestors. Each balance allocates at most
-- three six-word Bin nodes, plus one terminal node: 1+6*H per input entry.
-- Every nonempty create triple consumes an entry except its first unordered
-- tail marker; callers never pass an empty input to create. Thus at most
-- 2*n four-word triples cover its results. No collection between operations
-- is assumed. Returned nodes overlap the syntax term conservatively; keys
-- and values alias its payloads. Compiler/control/stack, comparisons, other
-- constructors and GC copies retain separate funding obligations.
ordinaryCapturedMapConstructionDataBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedMapConstructionDataBytes usage =
  48 * (entries + 6 * canonicalDhallMapEntryHeightSum usage) + 64 * entries
 where
  entries = canonicalDhallRecordFields usage + canonicalDhallUnionAlternatives usage

ordinaryCapturedMapDecodeDataBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedMapDecodeDataBytes usage =
  ordinaryCapturedMapPairBytes usage
    + ordinaryCapturedMapKeyProjectionBytes usage
    + ordinaryCapturedMapSeenSetBytes usage
    + ordinaryCapturedMapSeenSetAllocationBytes usage
    + ordinaryCapturedMapConstructionDataBytes usage

-- Raw path conversion data is distinct from the retained normalized path.
-- Every input character may produce a three-word cons and two-word Char; each
-- marked String has a two-word Nil. Charge all marked values beside the held
-- expression during extraction. Shared Char CAFs only reduce this term. This
-- bounds evaluated String data, not unpack/validation/control/GC/native peaks,
-- and grants no disjoint retained-state or program admission claim.
ordinaryCapturedPathConversionBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedPathConversionBytes usage =
  16 * canonicalDhallPathTextValues usage + 40 * canonicalDhallPathTextCharacters usage

-- On the pinned unprofiled 64-bit ABI, each String cons has three words.
-- A valid safe relative path cannot contain a parent traversal; makeAbsolute
-- preserves its longest ordinary component. Count only its unavoidable cons
-- cells and Nil, without claiming Char, prefix, parser, conversion or GC cost.
ordinaryCapturedPathMinimumStateBytes :: CanonicalDhallValueUsage -> Natural
ordinaryCapturedPathMinimumStateBytes usage = 16 + 24 * canonicalDhallPathComponentCharacters usage

checkOrdinaryCapturedPathState
  :: Natural -> CanonicalDhallValueUsage -> Either OrdinaryCapturedInputBudgetError ()
checkOrdinaryCapturedPathState available usage
  | available >= required = Right ()
  | otherwise = Left (OrdinaryCapturedPathStateUnderfunded required available)
 where
  required = ordinaryCapturedPathMinimumStateBytes usage

-- The pinned String decoder is lazy, including its generalized-UTF8 byte
-- representation. Before canonical re-encoding can retain the whole spine,
-- refuse as soon as this one field's unavoidable cons storage cannot fit.
-- Inspect no character values, and do not force a suffix beyond that refusal.
-- Char payloads, all other roots, parser/encoding/GC peaks remain separate.
checkOrdinaryCapturedWireStringState
  :: Natural -> String -> Either OrdinaryCapturedInputBudgetError ()
checkOrdinaryCapturedWireStringState available = go 0
 where
  go !count rest
    | required > available = Left (OrdinaryCapturedWireStringStateUnderfunded required available)
    | otherwise = case rest of
        [] -> Right ()
        _ : tailValue -> go (count + 1) tailValue
   where
    required = 16 + 24 * count

-- Match the existing streaming cons-only refusal, including its first-over
-- diagnostic, from a checked scalar count before the String is materialized.
-- Char values, other roots and complete construction/GC costs stay separate.
checkOrdinaryCapturedWireStringLength
  :: Natural -> Natural -> Either OrdinaryCapturedInputBudgetError ()
checkOrdinaryCapturedWireStringLength available count
  | available < 16 = Left (OrdinaryCapturedWireStringStateUnderfunded 16 available)
  | 16 + 24 * count <= available = Right ()
  | otherwise =
      Left
        ( OrdinaryCapturedWireStringStateUnderfunded
            (16 + 24 * (1 + (available - 16) `div` 24))
            available
        )

-- The full conservative pinned-ABI String data term. It can be derived from
-- the checked scalar count without constructing a list or Char objects.
ordinaryCapturedWireStringDataBytes :: Natural -> Natural
ordinaryCapturedWireStringDataBytes count =
  boxedRecordBytes [] + count * (boxedRecordBytes [0, 0] + boxedCharBytes '\0')

-- Complete evaluated budget-record data; source payloads retain their owners.
ordinaryCapturedInputBudgetNormalFormBytes :: OrdinaryCapturedInputBudget -> Natural
ordinaryCapturedInputBudgetNormalFormBytes
  ( InputBudget
      field1
      field2
      field3
      field4
      field5
      field6
      field7
      field8
      field9
      field10
      field11
      field12
      field13
      field14
      field15
      field16
      field17
      field18
      field19
      field20
      field21
      field22
      field23
      field24
      field25
      field26
      field27
    ) =
    boxedRecordBytes
      [ boxedNaturalBytes field1
      , boxedNaturalBytes field2
      , boxedNaturalBytes field3
      , boxedNaturalBytes field4
      , boxedNaturalBytes field5
      , boxedNaturalBytes field6
      , boxedNaturalBytes field7
      , boxedNaturalBytes field8
      , boxedNaturalBytes field9
      , boxedNaturalBytes field10
      , boxedNaturalBytes field11
      , boxedNaturalBytes field12
      , boxedNaturalBytes field13
      , boxedNaturalBytes field14
      , boxedNaturalBytes field15
      , boxedNaturalBytes field16
      , boxedNaturalBytes field17
      , boxedNaturalBytes field18
      , boxedNaturalBytes field19
      , boxedNaturalBytes field20
      , boxedNaturalBytes field21
      , boxedNaturalBytes field22
      , boxedNaturalBytes field23
      , boxedNaturalBytes field24
      , boxedNaturalBytes field25
      , boxedNaturalBytes field26
      , boxedNaturalBytes field27
      ]
