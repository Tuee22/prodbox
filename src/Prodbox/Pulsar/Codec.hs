module Prodbox.Pulsar.Codec
  ( decodePayload
  , encodePayload
  )
where

import Codec.Serialise (Serialise)
import Prodbox.Cbor
  ( CborPayload
  , decodeCanonicalCbor
  , encodeCanonicalCbor
  )

encodePayload :: (Serialise a) => a -> CborPayload
encodePayload =
  encodeCanonicalCbor

decodePayload :: (Serialise a) => CborPayload -> Either String a
decodePayload =
  decodeCanonicalCbor
