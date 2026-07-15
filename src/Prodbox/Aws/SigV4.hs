{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.66: pure AWS Signature Version 4 signing.
--
-- This is the byte-exact SigV4 algorithm used to sign S3 (MinIO) requests from
-- the native object-store client ("Prodbox.Minio.ObjectStoreNative"), replacing
-- the @aws@ CLI subprocess. Everything here is pure and unit-tested against
-- published AWS test vectors (the empty-payload SHA-256, the documented
-- signing-key derivation, and the @get-vanilla@ canonical request / signature).
--
-- Only the SigV4 pieces the object-store client needs are implemented: the
-- header-authorization flavor (single-chunk, fully signed payload), path-style
-- addressing, and the @x-amz-content-sha256@ payload-hash header. Chunked
-- signing and query-string ("presigned URL") signing are intentionally absent.
module Prodbox.Aws.SigV4
  ( SigV4Credentials (..)
  , SigV4Scope (..)
  , SigV4Request (..)
  , canonicalUri
  , canonicalQueryString
  , canonicalHeaders
  , signedHeaders
  , canonicalRequest
  , stringToSign
  , deriveSigningKey
  , sigV4Signature
  , sigV4AuthorizationHeader
  , hexSha256
  , sha256Hex
  , toHex
  , uriEncode
  , unsignedPayload
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List (sort, sortOn)
import Data.Word (Word8)

-- | The access key id and secret access key used to derive the signature.
data SigV4Credentials = SigV4Credentials
  { sigV4AccessKeyId :: ByteString
  , sigV4SecretAccessKey :: ByteString
  }

-- | The credential scope: the @YYYYMMDD@ date stamp, region, and service.
data SigV4Scope = SigV4Scope
  { sigV4DateStamp :: ByteString
  -- ^ @YYYYMMDD@
  , sigV4Region :: ByteString
  , sigV4Service :: ByteString
  }

-- | A request to sign. @sigV4Path@ is the raw (un-encoded) absolute path
-- (e.g. @\/bucket\/key@); @sigV4Query@ is the raw (un-encoded) query pairs;
-- @sigV4Headers@ must include @host@ and the @x-amz-date@
-- (@YYYYMMDDTHHMMSSZ@) header; @sigV4PayloadHashHex@ is the lowercase hex
-- SHA-256 of the body (or 'unsignedPayload').
data SigV4Request = SigV4Request
  { sigV4Method :: ByteString
  , sigV4Path :: ByteString
  , sigV4Query :: [(ByteString, ByteString)]
  , sigV4Headers :: [(ByteString, ByteString)]
  , sigV4PayloadHashHex :: ByteString
  }

-- | The literal used when the payload is not hashed.
unsignedPayload :: ByteString
unsignedPayload = "UNSIGNED-PAYLOAD"

-- | Lowercase hex SHA-256 of a byte string.
hexSha256 :: ByteString -> ByteString
hexSha256 = toHex . SHA256.hash

-- | Alias with the naming used elsewhere in the tree.
sha256Hex :: ByteString -> ByteString
sha256Hex = hexSha256

hmacSha256 :: ByteString -> ByteString -> ByteString
hmacSha256 = SHA256.hmac

toHex :: ByteString -> ByteString
toHex = BS.concatMap hexByte
 where
  hexByte w = BS.pack [nibble (w `shiftR` 4), nibble (w .&. 0x0f)]
  nibble n
    | n < 10 = 48 + n
    | otherwise = 87 + n -- 'a' = 97; 97 - 10 = 87

-- | Percent-encode per RFC 3986 SigV4 rules. Unreserved characters
-- (@A-Za-z0-9-._~@) pass through; @encodeSlash = False@ additionally passes
-- @\/@ through (used for the canonical URI path). Everything else becomes
-- @%XX@ with uppercase hex.
uriEncode :: Bool -> ByteString -> ByteString
uriEncode encodeSlash = BS.concatMap enc
 where
  enc :: Word8 -> ByteString
  enc c
    | isUnreserved c = BS.singleton c
    | c == 47 && not encodeSlash = BS.singleton c
    | otherwise = percentEncode c
  isUnreserved c =
    (c >= 65 && c <= 90) -- A-Z
      || (c >= 97 && c <= 122) -- a-z
      || (c >= 48 && c <= 57) -- 0-9
      || c == 45 -- '-'
      || c == 46 -- '.'
      || c == 95 -- '_'
      || c == 126 -- '~'
  percentEncode c =
    BS.pack [37, hexUpper (c `shiftR` 4), hexUpper (c .&. 0x0f)]
  hexUpper n
    | n < 10 = 48 + n
    | otherwise = 55 + n -- 'A' = 65; 65 - 10 = 55

-- | The canonical URI: each path segment URI-encoded once, @\/@ preserved (S3
-- single-encoding rule). An empty path canonicalizes to @\/@.
canonicalUri :: ByteString -> ByteString
canonicalUri path
  | BS.null path = "/"
  | otherwise = uriEncode False path

-- | The canonical query string: each key and value URI-encoded, pairs sorted by
-- encoded key, joined by @&@.
canonicalQueryString :: [(ByteString, ByteString)] -> ByteString
canonicalQueryString query =
  BS.intercalate "&" (map renderPair (sortOn fst encoded))
 where
  encoded = [(uriEncode True key, uriEncode True value) | (key, value) <- query]
  renderPair (key, value) = key <> "=" <> value

-- | The canonical headers block: each @lowercase(name):trim(value)@ followed by
-- a newline, sorted by lowercased name.
canonicalHeaders :: [(ByteString, ByteString)] -> ByteString
canonicalHeaders headers =
  BS.concat [name <> ":" <> value <> "\n" | (name, value) <- sortOn fst (map normalize headers)]
 where
  normalize (name, value) = (lowercaseAscii name, trimAscii value)

-- | The signed-headers list: sorted lowercased names joined by @;@.
signedHeaders :: [(ByteString, ByteString)] -> ByteString
signedHeaders headers =
  BS.intercalate ";" (sort (map (lowercaseAscii . fst) headers))

-- | The canonical request string.
canonicalRequest :: SigV4Request -> ByteString
canonicalRequest request =
  BS.concat
    [ sigV4Method request
    , "\n"
    , canonicalUri (sigV4Path request)
    , "\n"
    , canonicalQueryString (sigV4Query request)
    , "\n"
    , canonicalHeaders (sigV4Headers request)
    , "\n"
    , signedHeaders (sigV4Headers request)
    , "\n"
    , sigV4PayloadHashHex request
    ]

-- | The string-to-sign. @amzDate@ is the @YYYYMMDDTHHMMSSZ@ timestamp.
stringToSign :: SigV4Scope -> ByteString -> SigV4Request -> ByteString
stringToSign scope amzDate request =
  BS.concat
    [ "AWS4-HMAC-SHA256\n"
    , amzDate
    , "\n"
    , credentialScope scope
    , "\n"
    , hexSha256 (canonicalRequest request)
    ]

credentialScope :: SigV4Scope -> ByteString
credentialScope scope =
  BS.intercalate
    "/"
    [ sigV4DateStamp scope
    , sigV4Region scope
    , sigV4Service scope
    , "aws4_request"
    ]

-- | Derive the signing key by the HMAC chain
-- @HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")@.
deriveSigningKey :: ByteString -> SigV4Scope -> ByteString
deriveSigningKey secret scope =
  let kDate = hmacSha256 ("AWS4" <> secret) (sigV4DateStamp scope)
      kRegion = hmacSha256 kDate (sigV4Region scope)
      kService = hmacSha256 kRegion (sigV4Service scope)
   in hmacSha256 kService "aws4_request"

-- | The hex signature.
sigV4Signature :: SigV4Credentials -> SigV4Scope -> ByteString -> SigV4Request -> ByteString
sigV4Signature credentials scope amzDate request =
  let signingKey = deriveSigningKey (sigV4SecretAccessKey credentials) scope
   in toHex (hmacSha256 signingKey (stringToSign scope amzDate request))

-- | The complete @Authorization@ header value.
sigV4AuthorizationHeader
  :: SigV4Credentials -> SigV4Scope -> ByteString -> SigV4Request -> ByteString
sigV4AuthorizationHeader credentials scope amzDate request =
  BS.concat
    [ "AWS4-HMAC-SHA256 Credential="
    , sigV4AccessKeyId credentials
    , "/"
    , credentialScope scope
    , ", SignedHeaders="
    , signedHeaders (sigV4Headers request)
    , ", Signature="
    , sigV4Signature credentials scope amzDate request
    ]

lowercaseAscii :: ByteString -> ByteString
lowercaseAscii = BS.map toLowerWord
 where
  toLowerWord w
    | w >= 65 && w <= 90 = w + 32
    | otherwise = w

-- | Trim leading/trailing ASCII spaces and collapse internal runs of spaces to
-- a single space (SigV4 @Trimall@), operating on unquoted header values.
trimAscii :: ByteString -> ByteString
trimAscii = BS8.intercalate " " . filter (not . BS.null) . BS8.split ' '
