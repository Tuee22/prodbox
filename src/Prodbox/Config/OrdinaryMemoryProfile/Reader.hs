{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Closed field-reader transitions. Canonical readback belongs to the codec.
module Prodbox.Config.OrdinaryMemoryProfile.Reader
  ( ProfileCursor (..)
  , ProfileState
  , ProfileStep (..)
  , beginProfile
  , stepProfile
  , readOrdinaryMemoryProfile
  , constructorHeader
  , ordinaryMemoryProfileReaderStepDataBytes
  ) where

import Codec.CBOR.Decoding qualified as Decoding
import Codec.CBOR.Read qualified as Cbor
import Control.Monad.ST (runST)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic (Rep), K1, M1, U1, type (:*:), type (:+:))
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config qualified as C
import Prodbox.Config.OrdinaryMemoryProfile.Schema

-- Framing, the byte ceiling and canonical readback are checked by the caller.
readOrdinaryMemoryProfile
  :: ByteString -> Either OrdinaryMemoryProfileError (C.RuntimeMemoryProfile, Int)
readOrdinaryMemoryProfile bytes = drive (beginProfile bytes)
 where
  drive step = case step of
    ProfileRefused cause -> Left cause
    ProfileDecoded (ProfileCursor _ consumed) value -> Right (value, consumed)
    ProfileProgress {} -> let !next = stepProfile step in drive next

-- Every state carries evaluated data. No decoder callback or StateT binder
-- retains preceding fields. The driver tail-calls one closed transition.
-- Helper calls and the selected scalar SDK retain their separate control,
-- stack, construction and collection obligations.
data ProfileCursor = ProfileCursor !ByteString !Int
  deriving (Generic)

data ProfileRead value
  = ReadRefused !OrdinaryMemoryProfileError
  | ReadDone !ProfileCursor !value
  deriving (Generic)

data ProfileState
  = ProfileStart
  | ProfileApplication
  | ProfileScratch !Natural
  | ProfilePending !Natural !Natural
  | ProfileDeadline !Natural !Natural !Natural
  | ProfilePermit !Natural !Natural !Natural !(Maybe Natural)
  | ProfileFirstPeak !Natural !Natural !Natural !(Maybe Natural) !(Maybe Natural)
  | ProfileSecondPeak !Natural !Natural !Natural !(Maybe Natural) !(Maybe Natural) !Natural
  | ProfileHeap !Natural !Natural !Natural !C.ChildProcessBudgetConfig
  | ProfileKernel !Natural !Natural !Natural !C.ChildProcessBudgetConfig !Natural
  | ProfileNative !Natural !Natural !Natural !C.ChildProcessBudgetConfig !Natural !Natural
  | ProfileReserve !Natural !Natural !Natural !C.ChildProcessBudgetConfig !Natural !Natural !Natural
  | ProfileIdentity
      !Natural
      !Natural
      !Natural
      !C.ChildProcessBudgetConfig
      !Natural
      !Natural
      !Natural
      !Natural
  | ProfileMargin
      !Natural
      !Natural
      !Natural
      !C.ChildProcessBudgetConfig
      !Natural
      !Natural
      !Natural
      !Natural
  deriving (Generic)

data ProfileStep
  = ProfileRefused !OrdinaryMemoryProfileError
  | ProfileProgress !ProfileCursor !ProfileState
  | ProfileDecoded !ProfileCursor !C.RuntimeMemoryProfile
  deriving (Generic)

beginProfile :: ByteString -> ProfileStep
beginProfile bytes = ProfileProgress (ProfileCursor bytes 0) ProfileStart

stepProfile :: ProfileStep -> ProfileStep
stepProfile current = case current of
  ProfileRefused {} -> current
  ProfileDecoded {} -> current
  ProfileProgress cursor phase -> case phase of
    ProfileStart -> case record 10 cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next () -> ProfileProgress next ProfileApplication
    ProfileApplication -> case labelledNatural "bounded_application_state_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next value -> ProfileProgress next (ProfileScratch value)
    ProfileScratch application -> case labelledNatural "bounded_in_heap_transport_decode_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next scratch -> ProfileProgress next (ProfilePending application scratch)
    ProfilePending application scratch -> case labelledNatural "bounded_pending_persistence_state_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next pending -> ProfileProgress next (ProfileDeadline application scratch pending)
    ProfileDeadline application scratch pending -> case childDeadline cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next deadline -> ProfileProgress next (ProfilePermit application scratch pending deadline)
    ProfilePermit application scratch pending deadline -> case labelledOptional "permit_capacity" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next permit
        | permit == Just (fromIntegral ordinaryMemoryProfileRoles) ->
            ProfileProgress next (ProfileFirstPeak application scratch pending deadline permit)
        | otherwise -> ProfileRefused OrdinaryMemoryProfileMalformed
    ProfileFirstPeak application scratch pending deadline permit -> case readFirstPeak cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next first -> ProfileProgress next (ProfileSecondPeak application scratch pending deadline permit first)
    ProfileSecondPeak application scratch pending deadline permit first -> case natural cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next second ->
        let !tailPeaks = [second]
            !peaks = first : tailPeaks
            !child = C.ChildProcessBudgetConfig permit deadline peaks
         in ProfileProgress next (ProfileHeap application scratch pending child)
    ProfileHeap application scratch pending child -> case labelledNatural "heap_cap_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next heap -> ProfileProgress next (ProfileKernel application scratch pending child heap)
    ProfileKernel application scratch pending child heap -> case labelledNatural "kernel_cgroup_reserve_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next kernel -> ProfileProgress next (ProfileNative application scratch pending child heap kernel)
    ProfileNative application scratch pending child heap kernel -> case labelledNatural "native_non_heap_reserve_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next native -> ProfileProgress next (ProfileReserve application scratch pending child heap kernel native)
    ProfileReserve application scratch pending child heap kernel native -> case labelledNatural "other_heap_reserve_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next reserve ->
        ProfileProgress next (ProfileIdentity application scratch pending child heap kernel native reserve)
    ProfileIdentity application scratch pending child heap kernel native reserve -> case identity cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next () ->
        ProfileProgress next (ProfileMargin application scratch pending child heap kernel native reserve)
    ProfileMargin application scratch pending child heap kernel native reserve -> case labelledNatural "safety_margin_bytes" cursor of
      ReadRefused cause -> ProfileRefused cause
      ReadDone next margin ->
        let !name = ordinaryMemoryProfileIdentity
            !value = C.RuntimeMemoryProfile name application pending scratch reserve heap native child kernel margin
         in ProfileDecoded next value

-- Only constructor headers are derived here; referenced values retain their
-- own prospective typed-profile data term. Sum branches take the maximum
-- arity, products sum fields, and metadata wrappers do not allocate fields.
class FieldMaximum (fields :: Type -> Type) where
  fieldMaximum :: Proxy fields -> Natural
instance FieldMaximum U1 where fieldMaximum _ = 0
instance FieldMaximum (K1 index value) where fieldMaximum _ = 1
instance (FieldMaximum fields) => FieldMaximum (M1 metadata index fields) where
  fieldMaximum _ = fieldMaximum (Proxy @fields)
instance (FieldMaximum left, FieldMaximum right) => FieldMaximum (left :*: right) where
  fieldMaximum _ = fieldMaximum (Proxy @left) + fieldMaximum (Proxy @right)
instance (FieldMaximum left, FieldMaximum right) => FieldMaximum (left :+: right) where
  fieldMaximum _ = max (fieldMaximum (Proxy @left)) (fieldMaximum (Proxy @right))

constructorHeader
  :: forall value. (Generic value, FieldMaximum (Rep value)) => Proxy value -> Natural
constructorHeader _ = 8 * (1 + max 1 (fieldMaximum (Proxy @(Rep value))))

-- Current/next states and step envelopes, two cursor/offset graphs, two helper
-- result headers, an input view and one error enum. This is data at a step
-- boundary, not helper/SDK/compiler control, allocation/stack/GC/native peak.
ordinaryMemoryProfileReaderStepDataBytes :: Natural
ordinaryMemoryProfileReaderStepDataBytes =
  2 * constructorHeader (Proxy @ProfileState)
    + 2 * constructorHeader (Proxy @ProfileStep)
    + 2 * (constructorHeader (Proxy @ProfileCursor) + 16)
    + 2 * constructorHeader (Proxy @(ProfileRead ()))
    + 32
    + 16

malformed :: ProfileRead value
malformed = ReadRefused OrdinaryMemoryProfileMalformed

labelledNatural :: ByteString -> ProfileCursor -> ProfileRead Natural
labelledNatural name cursor = case label name cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone next () -> natural next

labelledOptional :: ByteString -> ProfileCursor -> ProfileRead (Maybe Natural)
labelledOptional name cursor = case label name cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone next () -> optionalNatural next

childDeadline :: ProfileCursor -> ProfileRead (Maybe Natural)
childDeadline cursor = case label "child_process_budget" cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone afterLabel () -> case record 3 afterLabel of
    ReadRefused cause -> ReadRefused cause
    ReadDone next () -> labelledOptional "action_deadline_milliseconds" next

readFirstPeak :: ProfileCursor -> ProfileRead Natural
readFirstPeak cursor = case label "simultaneous_peak_bytes" cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone afterLabel () -> case tagged 4 4 afterLabel of
    ReadRefused cause -> ReadRefused cause
    ReadDone afterTag () -> case nullValue afterTag of
      ReadRefused cause -> ReadRefused cause
      ReadDone next () -> natural next

identity :: ProfileCursor -> ProfileRead ()
identity cursor = case label "runtime_profile_id" cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone afterLabel () -> case tagged 2 18 afterLabel of
    ReadRefused cause -> ReadRefused cause
    ReadDone next () -> label "ordinary-cascade-host" next

record :: Word -> ProfileCursor -> ProfileRead ()
record count cursor = case tagged 2 8 cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone afterTag () -> case header 5 afterTag of
    ReadRefused cause -> ReadRefused cause
    ReadDone next actual
      | actual == count -> ReadDone next ()
      | otherwise -> malformed

label :: ByteString -> ProfileCursor -> ProfileRead ()
label expected cursor = case header 3 cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone (ProfileCursor bytes offset) size ->
    let count = Bytes.length expected
        matches !index
          | index == count = True
          | Bytes.index expected index == Bytes.index bytes (offset + index) = matches (index + 1)
          | otherwise = False
     in if size == fromIntegral count && count <= Bytes.length bytes - offset && matches 0
          then ReadDone (ProfileCursor bytes (offset + count)) ()
          else malformed

tagged :: Word -> Word -> ProfileCursor -> ProfileRead ()
tagged count tag cursor = case header 4 cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone afterCount actualCount -> case header 0 afterCount of
    ReadRefused cause -> ReadRefused cause
    ReadDone next actualTag
      | actualCount == count && actualTag == tag -> ReadDone next ()
      | otherwise -> malformed

nullValue :: ProfileCursor -> ProfileRead ()
nullValue cursor = case byte cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone next value
    | value == 0xf6 -> ReadDone next ()
    | otherwise -> malformed

-- Definite headers consume at most eight argument bytes. Nonminimal widths
-- retain decode-then-canonical-readback classification; every index is checked.
header :: Word -> ProfileCursor -> ProfileRead Word
header major cursor = case byte cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone next initial
    | initial `shiftR` 5 /= major -> malformed
    | otherwise -> case initial .&. 0x1f of
        value | value < 24 -> ReadDone next value
        24 -> argument next 1 0
        25 -> argument next 2 0
        26 -> argument next 4 0
        27 -> argument next 8 0
        _ -> malformed
 where
  argument :: ProfileCursor -> Int -> Word -> ProfileRead Word
  argument current 0 !value = ReadDone current value
  argument current remaining !value = case byte current of
    ReadRefused cause -> ReadRefused cause
    ReadDone next item -> argument next (remaining - 1) ((value `shiftL` 8) .|. item)

byte :: ProfileCursor -> ProfileRead Word
byte (ProfileCursor bytes offset)
  | offset < Bytes.length bytes =
      let !value = fromIntegral (Bytes.index bytes offset)
       in ReadDone (ProfileCursor bytes (offset + 1)) value
  | otherwise = malformed

natural :: ProfileCursor -> ProfileRead Natural
natural cursor = case tagged 2 15 cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone start@(ProfileCursor bytes offset) () -> case completePositive start of
    ReadRefused cause -> ReadRefused cause
    ReadDone _ () -> case readScalar bytes offset of
      Left cause -> ReadRefused cause
      Right (Scalar consumed value)
        | value >= 0 && consumed > 0 && consumed <= fromIntegral (Bytes.length bytes - offset) ->
            let !number = fromInteger value
             in ReadDone (ProfileCursor bytes (offset + fromIntegral consumed)) number
        | otherwise -> malformed

completePositive :: ProfileCursor -> ProfileRead ()
completePositive cursor@(ProfileCursor bytes offset)
  | offset >= Bytes.length bytes = malformed
  | otherwise = case Bytes.index bytes offset of
      value | value < 0x20 -> case header 0 cursor of
        ReadRefused cause -> ReadRefused cause
        ReadDone next _ -> ReadDone next ()
      0xc2 -> case byte cursor of
        ReadRefused cause -> ReadRefused cause
        ReadDone afterTag _ -> case header 2 afterTag of
          ReadRefused cause -> ReadRefused cause
          ReadDone next@(ProfileCursor _ payloadOffset) count
            | count <= fromIntegral (Bytes.length bytes - payloadOffset) -> ReadDone next ()
            | otherwise -> malformed
      _ -> malformed

optionalNatural :: ProfileCursor -> ProfileRead (Maybe Natural)
optionalNatural cursor = case header 4 cursor of
  ReadRefused cause -> ReadRefused cause
  ReadDone afterCount count -> case header 0 afterCount of
    ReadRefused cause -> ReadRefused cause
    ReadDone afterTag tag
      | count /= 3 -> malformed
      | otherwise -> case tag of
          5 -> case nullValue afterTag of
            ReadRefused cause -> ReadRefused cause
            ReadDone next () -> case natural next of
              ReadRefused cause -> ReadRefused cause
              ReadDone final value -> ReadDone final (Just value)
          0 -> case label "None" afterTag of
            ReadRefused cause -> ReadRefused cause
            ReadDone next () -> case label "Natural" next of
              ReadRefused cause -> ReadRefused cause
              ReadDone final () -> ReadDone final Nothing
          _ -> malformed

-- A scalar result contains no trailing input, lazy chunks or SDK continuation.
-- The numeric importer and its internal control/GC costs remain SDK-owned.
data ProfileScalar = Scalar !Cbor.ByteOffset !Integer

readScalar :: ByteString -> Int -> Either OrdinaryMemoryProfileError ProfileScalar
readScalar bytes offset = runST $ do
  decoder <- Cbor.deserialiseIncremental Decoding.decodeInteger
  case decoder of
    Cbor.Partial receive -> do
      complete <- receive (Just (Bytes.drop offset bytes))
      pure $ case complete of
        Cbor.Done _ consumed !value -> Right (Scalar consumed value)
        Cbor.Fail {} -> Left OrdinaryMemoryProfileMalformed
        Cbor.Partial {} -> Left OrdinaryMemoryProfileMalformed
    Cbor.Done {} -> pure (Left OrdinaryMemoryProfileMalformed)
    Cbor.Fail {} -> pure (Left OrdinaryMemoryProfileMalformed)
