{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Strict closed-profile data in the existing canonical Dhall binary format.
-- No general Expr tree, extraction dictionary or profile observation is built.
-- Data and source/encoding scratch still require independent funding/admission.
module Prodbox.Config.OrdinaryMemoryProfile
  ( OrdinaryMemoryProfileError (..)
  , OrdinaryMemoryProfileEncodingPlan
  , prepareOrdinaryMemoryProfileEncoding
  , ordinaryMemoryProfileEncodingPlanNormalFormBytes
  , ordinaryMemoryProfileEncodingPlanTokenNormalFormBytes
  , ordinaryMemoryProfileEncodingPlanBound
  , ordinaryMemoryProfileIdentity
  , ordinaryMemoryProfileRoles
  , ordinaryMemoryProfileMaximumBytes
  , ordinaryMemoryProfileWireBytes
  , ordinaryMemoryProfileEncodingBufferBytes
  , ordinaryMemoryProfileNormalFormBound
  , ordinaryMemoryProfileScalarValueBytes
  , ordinaryMemoryProfileReaderStepDataBytes
  , encodeOrdinaryMemoryProfile
  , decodeOrdinaryMemoryProfile
  ) where

import Codec.CBOR.Encoding qualified as Encoding
import Codec.CBOR.Write qualified as Cbor
import Control.Monad (unless)
import Data.Bits (countLeadingZeros, finiteBitSize)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Builder.Extra qualified as Builder
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Internal qualified as LazyInternal
import Data.Text (Text)
import Data.Text.Foreign qualified as Text
import GHC.Exts (Int (I#), Word (W#), indexWordArray#, sizeofByteArray#)
import GHC.Natural (BigNat (BN#), Natural, pattern NatJ#, pattern NatS#)
import Prodbox.Capacity.BoxedNormalForm
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.SettingsNormalForm (runtimeProfileNormalFormBytes)
import Prodbox.Config.OrdinaryMemoryProfile.Reader
  ( ordinaryMemoryProfileReaderStepDataBytes
  , readOrdinaryMemoryProfile
  )
import Prodbox.Config.OrdinaryMemoryProfile.Schema

-- A structural upper bound for the returned strict typed value only. The
-- fixed ten-field record and child record contain twelve Natural slots,
-- including a present deadline, permit and two peaks. A large Natural adds
-- at most its encoded payload plus 24 bytes above the small-Natural term:
-- 16 extra header bytes and at most seven bytes of limb rounding. All scalar
-- payload spans are disjoint within the checked wire. Nothing is cheaper.
-- This does not cover parsing, encoding, scalar conversion, GC or native RSS.
ordinaryMemoryProfileNormalFormBound :: Natural -> Natural
ordinaryMemoryProfileNormalFormBound inputBytes =
  runtimeProfileNormalFormBytes (smallProfile (Just 0)) + 12 * 24 + inputBytes

-- Positive scalar data only on the selected 64-bit ghc-bignum ABI. Import
-- allocates one ceil(bytes/8)-limb array, shrinks it in place and freezes that
-- same array. The Integer and Natural wrappers can coexist; conversion shares
-- a multiword array or collapses to a word. Charge both wrappers (16 each) and
-- the array header (16), even when the scalar is small. The supplied wire span
-- bounds its payload without importing it. SDK/control, input views, stack,
-- collection and native costs are excluded; this is not a reader certificate.
ordinaryMemoryProfileScalarValueBytes :: Natural -> Natural
ordinaryMemoryProfileScalarValueBytes wireBytes = 48 + 8 * ((wireBytes + 7) `div` 8)

smallProfile :: Maybe Natural -> C.RuntimeMemoryProfile
smallProfile deadline =
  C.RuntimeMemoryProfile
    ordinaryMemoryProfileIdentity
    0
    0
    0
    0
    0
    0
    (C.ChildProcessBudgetConfig (Just (fromIntegral ordinaryMemoryProfileRoles)) deadline [0, 0])
    0
    0

-- A fixed-size data program shared by the size and encoding interpreters.
-- Scalar values are references to the supplied typed profile, never expanded.
data Atom = List !Word | Map !Word | Word !Word | Null | Text !Text | Natural !Natural

profileAtoms :: C.RuntimeMemoryProfile -> Either OrdinaryMemoryProfileError [Atom]
profileAtoms value = do
  unless
    ( C.runtime_profile_id value == ordinaryMemoryProfileIdentity
        && C.permit_capacity child == Just (fromIntegral ordinaryMemoryProfileRoles)
    )
    (Left OrdinaryMemoryProfileInvalid)
  (firstPeak, secondPeak) <- case C.simultaneous_peak_bytes child of
    [a, b] -> Right (a, b)
    _ -> Left OrdinaryMemoryProfileInvalid
  pure (profileAtomsFor value firstPeak secondPeak)
 where
  child = C.child_process_budget value

profileAtomsFor :: C.RuntimeMemoryProfile -> Natural -> Natural -> [Atom]
-- The schema has one fixed prefix, one optional segment and one fixed suffix.
-- Cons each cell directly; no append interpreter copies intermediate spines.
-- Scalar and selector/control/GC costs retain their separate obligations.
profileAtomsFor value firstPeak secondPeak =
  List 2
    : Word 8
    : Map 10
    : Text "bounded_application_state_bytes"
    : List 2
    : Word 15
    : Natural (C.bounded_application_state_bytes value)
    : Text "bounded_in_heap_transport_decode_bytes"
    : List 2
    : Word 15
    : Natural (C.bounded_in_heap_transport_decode_bytes value)
    : Text "bounded_pending_persistence_state_bytes"
    : List 2
    : Word 15
    : Natural (C.bounded_pending_persistence_state_bytes value)
    : Text "child_process_budget"
    : List 2
    : Word 8
    : Map 3
    : Text "action_deadline_milliseconds"
    : deadlineAtoms (C.action_deadline_milliseconds child) afterDeadline
 where
  child = C.child_process_budget value
  afterDeadline =
    [ Text "permit_capacity"
    , List 3
    , Word 5
    , Null
    , List 2
    , Word 15
    , Natural (fromIntegral ordinaryMemoryProfileRoles)
    , Text "simultaneous_peak_bytes"
    , List 4
    , Word 4
    , Null
    , List 2
    , Word 15
    , Natural firstPeak
    , List 2
    , Word 15
    , Natural secondPeak
    , Text "heap_cap_bytes"
    , List 2
    , Word 15
    , Natural (C.heap_cap_bytes value)
    , Text "kernel_cgroup_reserve_bytes"
    , List 2
    , Word 15
    , Natural (C.kernel_cgroup_reserve_bytes value)
    , Text "native_non_heap_reserve_bytes"
    , List 2
    , Word 15
    , Natural (C.native_non_heap_reserve_bytes value)
    , Text "other_heap_reserve_bytes"
    , List 2
    , Word 15
    , Natural (C.other_heap_reserve_bytes value)
    , Text "runtime_profile_id"
    , List 2
    , Word 18
    , Text ordinaryMemoryProfileIdentity
    , Text "safety_margin_bytes"
    , List 2
    , Word 15
    , Natural (C.safety_margin_bytes value)
    ]

deadlineAtoms :: Maybe Natural -> [Atom] -> [Atom]
deadlineAtoms value rest = case value of
  Nothing -> List 3 : Word 0 : Text "None" : Text "Natural" : rest
  Just present -> List 3 : Word 5 : Null : List 2 : Word 15 : Natural present : rest

ordinaryMemoryProfileWireBytes
  :: C.RuntimeMemoryProfile -> Either OrdinaryMemoryProfileError Natural
ordinaryMemoryProfileWireBytes value = profileAtoms value >>= checkedSize

-- The selected CBOR writer requests nine bytes before each token, including
-- its terminal continuation. All variable payload writers here use their exact
-- lengths: fixed UTF8 text and positive GMP limbs. Nine spare bytes therefore
-- let the entire checked program finish in one buffer, including TkEnd.
-- The existing 65536-byte preflight makes the later Int conversion safe.
ordinaryMemoryProfileEncodingBufferBytes :: Natural -> Natural
ordinaryMemoryProfileEncodingBufferBytes wireBytes = wireBytes + encodingLookaheadBytes

encodingLookaheadBytes :: Natural
encodingLookaheadBytes = 9

checkedSize :: [Atom] -> Either OrdinaryMemoryProfileError Natural
checkedSize atoms =
  let !size = foldl' (\total atom -> total + atomBytes atom) 0 atoms
   in if size <= fromIntegral ordinaryMemoryProfileMaximumBytes
        then Right size
        else Left OrdinaryMemoryProfileTooLarge

atomBytes :: Atom -> Natural
atomBytes atom = case atom of
  List count -> headerBytes (fromIntegral count)
  Map count -> headerBytes (fromIntegral count)
  Word value -> headerBytes (fromIntegral value)
  Null -> 1
  Text value ->
    let size = fromIntegral (Text.lengthWord8 value)
     in headerBytes size + size
  Natural value
    | value <= fromIntegral (maxBound :: Word) -> headerBytes value
    | otherwise ->
        let bytes = (naturalBits value + 7) `div` 8
         in 1 + headerBytes bytes + bytes

headerBytes :: Natural -> Natural
headerBytes value
  | value < 24 = 1
  | value <= 0xff = 2
  | value <= 0xffff = 3
  | value <= 0xffffffff = 5
  | otherwise = 9

-- Selected 64-bit GHC Natural representation. Count bits from the highest
-- limb without constructing an Integer, decimal String or byte payload.
-- The accumulated bit count stays Natural; only a validated array index is Int.
naturalBits :: Natural -> Natural
naturalBits (NatS# value) = fromIntegral (finiteBitSize (0 :: Word) - countLeadingZeros (W# value))
naturalBits (NatJ# (BN# array)) =
  let size = I# (sizeofByteArray# array) `div` wordBytes
   in if size <= 0
        then 0
        else case size - 1 of
          index@(I# offset) ->
            fromIntegral index * fromIntegral wordBits
              + fromIntegral (wordBits - countLeadingZeros (W# (indexWordArray# array offset)))
 where
  wordBits = finiteBitSize (0 :: Word)
  wordBytes = wordBits `div` 8

-- The constructor is private: its exact size and fully evaluated data program
-- come from one checked preflight. It carries no callback or resource permit.
-- Strict Atom fields and checkedSize's complete fold force every list element
-- before success. Direct cons construction creates no intermediate append spines.
data OrdinaryMemoryProfileEncodingPlan = EncodingPlan !Natural ![Atom] !Encoding.Tokens

prepareOrdinaryMemoryProfileEncoding
  :: C.RuntimeMemoryProfile -> Either OrdinaryMemoryProfileError OrdinaryMemoryProfileEncodingPlan
prepareOrdinaryMemoryProfileEncoding value = do
  atoms <- profileAtoms value
  expected <- checkedSize atoms
  let !tokens = tokensFor atoms
  pure $! EncodingPlan expected atoms tokens

ordinaryMemoryProfileEncodingPlanNormalFormBytes :: OrdinaryMemoryProfileEncodingPlan -> Natural
ordinaryMemoryProfileEncodingPlanNormalFormBytes (EncodingPlan expected atoms _) = planNormalFormBytes expected atoms

ordinaryMemoryProfileEncodingPlanTokenNormalFormBytes
  :: OrdinaryMemoryProfileEncodingPlan -> Natural
ordinaryMemoryProfileEncodingPlanTokenNormalFormBytes (EncodingPlan _ atoms _) = tokensNormalFormBytes atoms

planNormalFormBytes :: Natural -> [Atom] -> Natural
planNormalFormBytes expected atoms =
  boxedRecordBytes
    [boxedNaturalBytes expected, boxedListBytes atomNormalFormBytes atoms, tokensNormalFormBytes atoms]

atomNormalFormBytes :: Atom -> Natural
atomNormalFormBytes atom = case atom of
  List count -> boxedRecordBytes [boxedWordBytes count]
  Map count -> boxedRecordBytes [boxedWordBytes count]
  Word value -> boxedRecordBytes [boxedWordBytes value]
  Null -> boxedRecordBytes []
  Text value -> boxedRecordBytes [boxedTextBytes value]
  Natural value -> boxedRecordBytes [boxedNaturalBytes value]

-- Each fixed optional branch is derived from the same atom producer. Scalars
-- add at most their disjoint wire payload plus 24 bytes per scalar slot above
-- each small-value template. Charge Natural and converted Integer payloads
-- independently, including the token Integer wrappers and limbs; actual GMP
-- sharing may make the observed graph smaller. The size field stays a small
-- Natural under the existing ceiling. Text labels are fixed owned CAFs.
-- This bounds evaluated atom/token data, excluding construction/conversion
-- transients, writer continuations, GC and native state.
ordinaryMemoryProfileEncodingPlanBound :: Natural -> Natural
ordinaryMemoryProfileEncodingPlanBound inputBytes =
  max (template (Just 0)) (template Nothing) + 2 * (12 * 24 + inputBytes)
 where
  template deadline =
    planNormalFormBytes 0 (profileAtomsFor (smallProfile deadline) 0 0)

encodeOrdinaryMemoryProfile
  :: C.RuntimeMemoryProfile -> Either OrdinaryMemoryProfileError ByteString
encodeOrdinaryMemoryProfile value = prepareOrdinaryMemoryProfileEncoding value >>= encodePreparedProfile

encodePreparedProfile
  :: OrdinaryMemoryProfileEncodingPlan -> Either OrdinaryMemoryProfileError ByteString
encodePreparedProfile (EncodingPlan expected _ tokens) =
  let capacity = fromIntegral (ordinaryMemoryProfileEncodingBufferBytes expected)
      encoded =
        Builder.toLazyByteStringWith
          (Builder.untrimmedStrategy capacity capacity)
          Lazy.empty
          -- Only this complete writer consumes the closed token stream, with
          -- TkEnd. No composable Encoding or continuation leaves this module.
          (Cbor.toBuilder (Encoding.Encoding (const tokens)))
   in -- A second chunk contradicts this writer's derived storage schedule.
      -- Refuse that disagreement before any concatenation allocation.
      case encoded of
        LazyInternal.Chunk bytes LazyInternal.Empty
          | fromIntegral (Bytes.length bytes) == expected -> Right bytes
        _ -> Left OrdinaryMemoryProfileMalformed

-- Force each tail and strict scalar field before returning the token stream.
-- Constructors match the selected SDK's six encoding primitives exactly.
-- This removes the lazy Endo composition chain from the writer's live input.
tokensFor :: [Atom] -> Encoding.Tokens
tokensFor [] = Encoding.TkEnd
tokensFor (atom : rest) =
  let !tailTokens = tokensFor rest
   in case atom of
        List count -> Encoding.TkListLen count tailTokens
        Map count -> Encoding.TkMapLen count tailTokens
        Word value -> Encoding.TkWord value tailTokens
        Null -> Encoding.TkNull tailTokens
        Text value -> Encoding.TkString value tailTokens
        Natural value -> Encoding.TkInteger (toInteger value) tailTokens

-- The private factory fixes every token constructor from the same atoms.
-- Fields are charged boxed even when the pinned SDK unpacks them. Integer
-- projection includes its wrapper and limb storage independently of Natural.
tokensNormalFormBytes :: [Atom] -> Natural
tokensNormalFormBytes = foldl' (\total atom -> total + tokenAtomNormalFormBytes atom) 16

tokenAtomNormalFormBytes :: Atom -> Natural
tokenAtomNormalFormBytes atom = case atom of
  List count -> boxedRecordBytes [boxedWordBytes count, 0]
  Map count -> boxedRecordBytes [boxedWordBytes count, 0]
  Word value -> boxedRecordBytes [boxedWordBytes value, 0]
  Null -> boxedRecordBytes [0]
  Text value -> boxedRecordBytes [boxedTextBytes value, 0]
  Natural value -> boxedRecordBytes [boxedIntegerBytes (toInteger value), 0]

decodeOrdinaryMemoryProfile
  :: ByteString -> Either OrdinaryMemoryProfileError C.RuntimeMemoryProfile
decodeOrdinaryMemoryProfile bytes = do
  unless
    (Bytes.length bytes <= ordinaryMemoryProfileMaximumBytes)
    (Left OrdinaryMemoryProfileTooLarge)
  (value, consumed) <- readOrdinaryMemoryProfile bytes
  unless (consumed == Bytes.length bytes) (Left OrdinaryMemoryProfileMalformed)
  canonical <- encodeOrdinaryMemoryProfile value
  unless (canonical == bytes) (Left OrdinaryMemoryProfileNonCanonical)
  pure value
