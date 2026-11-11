{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Locate the existing opaque profile field without importing surrounding
-- String, Text or numeric values. Definite CBOR items need only one aggregate
-- pending-item counter, even for nested collections; no input-sized stack is
-- constructed. This locator grants neither canonicality nor admission.
module Prodbox.ControlPlane.OrdinaryWireProfile
  ( OrdinaryWireProfileLayout
  , ordinaryWireProfileLayout
  , ordinaryWireFieldLayout
  , OrdinaryWireProfileError (..)
  , locateOrdinaryWireProfile
  , locateOrdinaryWireString
  , ordinaryInitialProfileDataBytes
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Proxy (Proxy (..))
import Data.Word (Word64)
import GHC.Generics (Generic (Rep), K1, M1, U1, type (:*:))
import GHC.TypeLits (ErrorMessage (Text), TypeError)
import GHC.TypeNats (KnownNat, Nat, natVal, type (+))
import Numeric.Natural (Natural)
import Prodbox.Capacity.BoxedNormalForm (boxedRecordBytes)
import Prodbox.Config.OrdinaryMemoryProfile (ordinaryMemoryProfileScalarValueBytes)

-- No sum equation: changing either record to multiple constructors requires
-- a new wire review rather than silently choosing a constructor tag.
type family FieldCount fields :: Nat where
  FieldCount U1 = 0
  FieldCount (K1 index value) = 1
  FieldCount (M1 metadata index fields) = FieldCount fields
  FieldCount (left :*: right) = FieldCount left + FieldCount right

type family FieldIndex wanted fields :: Maybe Nat where
  FieldIndex wanted U1 = 'Nothing
  FieldIndex wanted (K1 index wanted) = 'Just 0
  FieldIndex wanted (K1 index other) = 'Nothing
  FieldIndex wanted (M1 metadata index fields) = FieldIndex wanted fields
  FieldIndex wanted (left :*: right) =
    SelectIndex (FieldIndex wanted left) (FieldCount left) (FieldIndex wanted right)

type family MatchingFields wanted fields :: Nat where
  MatchingFields wanted U1 = 0
  MatchingFields wanted (K1 index wanted) = 1
  MatchingFields wanted (K1 index other) = 0
  MatchingFields wanted (M1 metadata index fields) = MatchingFields wanted fields
  MatchingFields wanted (left :*: right) = MatchingFields wanted left + MatchingFields wanted right

type family SelectIndex left offset right :: Maybe Nat where
  SelectIndex ('Just value) offset right = 'Just value
  SelectIndex 'Nothing offset ('Just value) = 'Just (offset + value)
  SelectIndex 'Nothing offset 'Nothing = 'Nothing

type family RequiredIndex found :: Nat where
  RequiredIndex ('Just value) = value
  RequiredIndex 'Nothing =
    TypeError ('Text "ordinary selected field is absent from its actual record")

data OrdinaryWireProfileLayout = Layout !Natural !Natural !Natural !Natural

ordinaryWireProfileLayout
  :: forall request profile
   . ( Generic request
     , Generic profile
     , MatchingFields profile (Rep request) ~ 1
     , MatchingFields ByteString (Rep profile) ~ 1
     , KnownNat (FieldCount (Rep request))
     , KnownNat (FieldCount (Rep profile))
     , KnownNat (RequiredIndex (FieldIndex profile (Rep request)))
     , KnownNat (RequiredIndex (FieldIndex ByteString (Rep profile)))
     )
  => Proxy request -> Proxy profile -> OrdinaryWireProfileLayout
ordinaryWireProfileLayout request profile = ordinaryWireFieldLayout request profile (Proxy @ByteString)

ordinaryWireFieldLayout
  :: forall request container selected
   . ( Generic request
     , Generic container
     , MatchingFields container (Rep request) ~ 1
     , MatchingFields selected (Rep container) ~ 1
     , KnownNat (FieldCount (Rep request))
     , KnownNat (FieldCount (Rep container))
     , KnownNat (RequiredIndex (FieldIndex container (Rep request)))
     , KnownNat (RequiredIndex (FieldIndex selected (Rep container)))
     )
  => Proxy request -> Proxy container -> Proxy selected -> OrdinaryWireProfileLayout
ordinaryWireFieldLayout _ _ _ =
  Layout
    (natVal (Proxy @(FieldCount (Rep request))))
    (natVal (Proxy @(RequiredIndex (FieldIndex container (Rep request)))))
    (natVal (Proxy @(FieldCount (Rep container))))
    (natVal (Proxy @(RequiredIndex (FieldIndex selected (Rep container)))))

data OrdinaryWireProfileError = OrdinaryWireProfileMalformed | OrdinaryWireProfileTooLarge
  deriving (Eq, Show)

data Header = Header !Word64 !Word64 !Int

data FieldKind = OpaqueProfile | SerialisedString

locateOrdinaryWireProfile
  :: OrdinaryWireProfileLayout -> Int -> ByteString -> Either OrdinaryWireProfileError ByteString
locateOrdinaryWireProfile = locateField OpaqueProfile

locateOrdinaryWireString
  :: OrdinaryWireProfileLayout -> Int -> ByteString -> Either OrdinaryWireProfileError ByteString
locateOrdinaryWireString = locateField SerialisedString

locateField
  :: FieldKind
  -> OrdinaryWireProfileLayout
  -> Int
  -> ByteString
  -> Either OrdinaryWireProfileError ByteString
locateField kind (Layout requestFields profileIndex profileFields memoryIndex) maximumProfile bytes = do
  if maximumProfile < 0 then Left OrdinaryWireProfileMalformed else Right ()
  start <- record (requestFields + 1) 0
  profile <- skipFields profileIndex start
  fields <- record (profileFields + 1) profile
  memory <- skipFields memoryIndex fields
  Header major count payload <- header memory
  let accepted = case kind of
        OpaqueProfile -> major == 2
        SerialisedString -> major == 2 || major == 3
  if not accepted
    then malformed
    else do
      end <- bodyEnd count payload
      if count > fromIntegral maximumProfile
        then Left OrdinaryWireProfileTooLarge
        else Right (Bytes.take (end - payload) (Bytes.drop payload bytes))
 where
  size = Bytes.length bytes
  malformed = Left OrdinaryWireProfileMalformed
  record :: Natural -> Int -> Either OrdinaryWireProfileError Int
  record count offset = do
    Header major actual next <- header offset
    if major /= 4 || fromIntegral actual /= count
      then malformed
      else do
        Header tagMajor tag final <- header next
        if tagMajor == 0 && tag == 0 then Right final else malformed
  skipFields :: Natural -> Int -> Either OrdinaryWireProfileError Int
  skipFields count offset
    | count > fromIntegral (size - offset) = malformed
    | otherwise = goFields (fromIntegral count :: Int) offset
  goFields :: Int -> Int -> Either OrdinaryWireProfileError Int
  goFields 0 !offset = Right offset
  goFields remaining !offset = do
    next <- skipItem 1 offset
    goFields (remaining - 1) next
  skipItem :: Int -> Int -> Either OrdinaryWireProfileError Int
  skipItem 0 !offset = Right offset
  skipItem !pending !offset = do
    Header major argument next <- header offset
    case major of
      0 -> skipItem (pending - 1) next
      1 -> skipItem (pending - 1) next
      2 -> bodyEnd argument next >>= skipItem (pending - 1)
      3 -> bodyEnd argument next >>= skipItem (pending - 1)
      4 -> collection pending argument next
      5
        | argument <= fromIntegral ((size - next) `div` 2) -> collection pending (2 * argument) next
        | otherwise -> malformed
      6 -> skipItem pending next
      7 -> skipItem (pending - 1) next
      _ -> malformed
  collection :: Int -> Word64 -> Int -> Either OrdinaryWireProfileError Int
  collection pending children next
    | pending - 1 > size - next = malformed
    | children > fromIntegral (size - next - (pending - 1)) = malformed
    | otherwise = skipItem (pending - 1 + fromIntegral children) next
  bodyEnd :: Word64 -> Int -> Either OrdinaryWireProfileError Int
  bodyEnd count offset
    | count <= fromIntegral (size - offset) = Right (offset + fromIntegral count)
    | otherwise = malformed
  header :: Int -> Either OrdinaryWireProfileError Header
  header offset
    | offset < 0 || offset >= size = malformed
    | otherwise =
        let initial = Bytes.index bytes offset
            major = fromIntegral (initial `shiftR` 5)
            argument = initial .&. 31
         in case argument of
              value | value < 24 -> Right (Header major (fromIntegral value) (offset + 1))
              24 -> readArgument major 1 (offset + 1) 0
              25 -> readArgument major 2 (offset + 1) 0
              26 -> readArgument major 4 (offset + 1) 0
              27 -> readArgument major 8 (offset + 1) 0
              _ -> malformed
  readArgument :: Word64 -> Int -> Int -> Word64 -> Either OrdinaryWireProfileError Header
  readArgument major 0 !offset !value = Right (Header major value offset)
  readArgument major count !offset !value
    | offset >= size = malformed
    | otherwise =
        readArgument
          major
          (count - 1)
          (offset + 1)
          ((value `shiftL` 8) .|. fromIntegral (Bytes.index bytes offset))

-- Retained/explicit data only: two actual fixed layouts, two header results,
-- three views and the source/heap/application operand. Both selected profile
-- scalars have disjoint payloads inside one profile ceiling. Compared with one
-- scalar, another pair of wrappers/array header costs48 bytes and independent
-- limb rounding costs at most8 more. Count-result and field-kind data join it.
-- Source payloads retain their established owners. Loop/compiler/SDK control,
-- construction, collection, stack and native peaks remain separate obligations.
ordinaryInitialProfileDataBytes :: Natural -> Natural
ordinaryInitialProfileDataBytes maximumProfile =
  2 * boxedRecordBytes [16, 16, 16, 16]
    + 2 * boxedRecordBytes [16, 16, 16]
    + 96
    + 16
    + 32
    + boxedRecordBytes [boxedRecordBytes [0, 16]]
    + boxedRecordBytes [0, ordinaryMemoryProfileScalarValueBytes maximumProfile + 56, 0]
