{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Cbor
  ( CborPayload (..)
  , decodeCanonicalCbor
  , encodeCanonicalCbor
  , cborPayloadFromJsonValue
  )
where

import Codec.Serialise
  ( Serialise
  , deserialiseOrFail
  , serialise
  )
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Scientific qualified as Scientific
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import GHC.Generics (Generic)

newtype CborPayload = CborPayload {cborPayloadBytes :: BS.ByteString}
  deriving (Eq, Show, Generic)

instance Serialise CborPayload

encodeCanonicalCbor :: (Serialise a) => a -> CborPayload
encodeCanonicalCbor =
  CborPayload . BL.toStrict . serialise

decodeCanonicalCbor :: (Serialise a) => CborPayload -> Either String a
decodeCanonicalCbor (CborPayload bytes) =
  case deserialiseOrFail (BL.fromStrict bytes) of
    Left err -> Left (show err)
    Right value -> Right value

data CborJsonValue
  = CborJsonNull
  | CborJsonBool Bool
  | CborJsonText Text.Text
  | CborJsonNumber Text.Text
  | CborJsonArray [CborJsonValue]
  | CborJsonObject [(Text.Text, CborJsonValue)]
  deriving (Eq, Show, Generic)

instance Serialise CborJsonValue

cborPayloadFromJsonValue :: Value -> CborPayload
cborPayloadFromJsonValue =
  CborPayload . BL.toStrict . serialise . jsonValueToCborValue

jsonValueToCborValue :: Value -> CborJsonValue
jsonValueToCborValue value =
  case value of
    Object obj ->
      CborJsonObject
        [ (Key.toText key, jsonValueToCborValue child)
        | (key, child) <- sortBy (comparing (Key.toText . fst)) (KeyMap.toList obj)
        ]
    Array arr -> CborJsonArray (map jsonValueToCborValue (Vector.toList arr))
    String text -> CborJsonText text
    Number number ->
      CborJsonNumber (Text.pack (Scientific.formatScientific Scientific.Generic Nothing number))
    Bool bool -> CborJsonBool bool
    Null -> CborJsonNull
