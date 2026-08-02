{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.50: the shared bounded, versioned, canonical wire codec for the
-- standing control-plane role servers.
--
-- The Lifecycle Authority migration route (Increment K) fixed a request framing in
-- 'Prodbox.Lifecycle.Authority.Migration': a 'Serialise' envelope carrying a schema
-- version and the payload, decoded under a maximum-size bound, a supported-version
-- check, and a canonical round-trip check, so a corrupt, oversized, non-canonical,
-- or wrong-version request body is refused before it reaches a decision. This
-- module lifts that exact framing into one generic codec every other fronted role
-- reuses for request and response payloads, so the roles cannot each reinvent —
-- or subtly diverge on — the bound/version/canonical discipline. Migration keeps
-- its own byte-frozen copy; the roles brought to codec parity here (Authority
-- Backup, TLS Retention) route through this shared codec.
--
-- Everything here is pure and total. Binding a role's decoded request to its
-- production retained store and dispatching the raw socket body to its handler is
-- the live-coupled follow-on (Standard-O); this codec fixes the request framing so
-- that follow-on cannot loosen the bound/version/canonical guarantees.
module Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , controlPlaneRequestCodecToken
  , controlPlaneResponseCodecToken
  , currentControlPlaneRequestVersion
  , currentControlPlaneResponseVersion
  , encodeControlPlaneRequest
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  , decodeControlPlaneResponse
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Why a control-plane request body was refused before it reached a decision. The
-- taxonomy matches the migration route's 'MigrationCodecError' exactly: an oversized
-- body, an undecodable body, an unsupported schema version, and a well-formed but
-- non-canonical encoding are each distinct.
data ControlPlaneRequestCodecError
  = -- | The body exceeds the caller-supplied maximum (or the maximum is negative).
    ControlPlaneRequestTooLarge
  | -- | The body is not a decodable envelope.
    ControlPlaneRequestInvalid
  | -- | The envelope decodes but carries an unsupported schema version.
    ControlPlaneRequestUnsupportedVersion
  | -- | The envelope decodes at the supported version but is not its own canonical
    -- serialization (a non-canonical re-encoding of the same value is refused).
    ControlPlaneRequestNonCanonical
  deriving stock (Eq, Show)

-- | Responses use the same stable wire-error taxonomy as requests.  The alias
-- is deliberate: one canonical envelope and one error algebra prevent a client
-- from accepting bytes that the server-side decoder would refuse.
type ControlPlaneResponseCodecError = ControlPlaneRequestCodecError

-- | Stable kebab token for a codec error, for a role's @bad-request@ summary body.
controlPlaneRequestCodecToken :: ControlPlaneRequestCodecError -> Text
controlPlaneRequestCodecToken err = case err of
  ControlPlaneRequestTooLarge -> "too-large"
  ControlPlaneRequestInvalid -> "invalid"
  ControlPlaneRequestUnsupportedVersion -> "unsupported-version"
  ControlPlaneRequestNonCanonical -> "non-canonical"

controlPlaneResponseCodecToken :: ControlPlaneResponseCodecError -> Text
controlPlaneResponseCodecToken = controlPlaneRequestCodecToken

-- | The versioned request envelope: a schema version plus the role's payload. A
-- version bump lets a role evolve its request shape without a silent misparse.
data RequestEnvelope a = RequestEnvelope
  { requestEnvelopeVersion :: !Word
  , requestEnvelopePayload :: !a
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The one supported request-envelope schema version.
currentControlPlaneRequestVersion :: Word
currentControlPlaneRequestVersion = 1

-- | Responses intentionally share the request-envelope version.  A future
-- incompatible framing change must bump both together or introduce a distinct
-- response envelope explicitly.
currentControlPlaneResponseVersion :: Word
currentControlPlaneResponseVersion = currentControlPlaneRequestVersion

-- | Encode a role request payload as a bounded, canonical, versioned envelope.
encodeControlPlaneRequest :: (Serialise a) => a -> ByteString
encodeControlPlaneRequest payload =
  serialise
    RequestEnvelope
      { requestEnvelopeVersion = currentControlPlaneRequestVersion
      , requestEnvelopePayload = payload
      }

-- | Decode a role request payload from a body, bounding the size, checking the
-- schema version, and requiring the exact canonical encoding. @maximumBytes@ bounds
-- the request-command framing; a negative bound refuses everything.
decodeControlPlaneRequest
  :: forall a
   . (Serialise a)
  => Int
  -> ByteString
  -> Either ControlPlaneRequestCodecError a
decodeControlPlaneRequest maximumBytes bytes
  | maximumBytes < 0 = Left ControlPlaneRequestTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left ControlPlaneRequestTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left ControlPlaneRequestInvalid
        Right (envelope :: RequestEnvelope a)
          | requestEnvelopeVersion envelope /= currentControlPlaneRequestVersion ->
              Left ControlPlaneRequestUnsupportedVersion
          | serialise envelope /= bytes -> Left ControlPlaneRequestNonCanonical
          | otherwise -> Right (requestEnvelopePayload envelope)

-- | Encode a role response payload with the same versioned canonical envelope.
encodeControlPlaneResponse :: (Serialise a) => a -> ByteString
encodeControlPlaneResponse = encodeControlPlaneRequest

-- | Decode a role response payload under an explicit byte bound.
decodeControlPlaneResponse
  :: (Serialise a)
  => Int
  -> ByteString
  -> Either ControlPlaneResponseCodecError a
decodeControlPlaneResponse = decodeControlPlaneRequest
