{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe request values shared by the Bootstrap Broker router and
-- admission lane.  The wire decoder lives at the HTTP boundary; this module
-- contains only validated, bounded values and never gives a secret payload a
-- JSON or ordinary 'Show' instance.
module Prodbox.Bootstrap.Broker.Request
  ( BrokerOperationTag (..)
  , HttpMethod (..)
  , LoopbackAddress
  , mkLoopbackAddress
  , renderLoopbackAddress
  , BrokerServiceIdentity
  , mkBrokerServiceIdentity
  , renderBrokerServiceIdentity
  , IdempotencyKey
  , mkIdempotencyKey
  , renderIdempotencyKey
  , RequestDigest
  , mkRequestDigest
  , renderRequestDigest
  , requestDigestForBytes
  , SecretPayload
  , mkSecretPayload
  , secretPayloadLength
  , RequestMetadata (..)
  , BrokerRequest (..)
  , requestAbsoluteDeadline
  , requestCarriesSecret
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Request.Internal
  ( SecretPayload
  , mkSecretPayload
  , secretPayloadLength
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration
  , deadlineAtOffset
  )

-- | The closed operation tag carried by a decoded broker request.  There is no
-- generic Vault, MinIO, KV, command, URL, or coordinate constructor.
data BrokerOperationTag
  = BrokerHealth
  | BrokerReadiness
  | ObserveBootstrapStatus
  | EnsureVaultInitialized
  | EnsureVaultUnsealed
  | SealVault
  | RotateUnlockBundle
  | RotateTransitKey
  | RecoverAmbiguousInitialization
  | ReconcileVaultBaseline
  | ObserveVaultPki
  | IssueVaultPkiTestCertificate
  | CommitChildInitCustody
  | DeliverChildRecovery
  | ObserveChildRecoveryDelivery
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data HttpMethod
  = HttpGet
  | HttpPost
  deriving stock (Eq, Ord, Show)

data LoopbackAddress
  = LoopbackV4
  | LoopbackV6
  deriving stock (Eq, Ord, Show)

-- | Accept literal loopback addresses only.  In particular, a DNS name such as
-- @localhost@ is deliberately rejected so request authentication cannot be
-- weakened by resolver configuration.
mkLoopbackAddress :: Text -> Either String LoopbackAddress
mkLoopbackAddress raw =
  case raw of
    "127.0.0.1" -> Right LoopbackV4
    "::1" -> Right LoopbackV6
    _ -> Left "bootstrap broker caller/listener must be the literal loopback address 127.0.0.1 or ::1"

renderLoopbackAddress :: LoopbackAddress -> Text
renderLoopbackAddress address =
  case address of
    LoopbackV4 -> "127.0.0.1"
    LoopbackV6 -> "::1"

newtype BrokerServiceIdentity = BrokerServiceIdentity Text
  deriving stock (Eq, Ord, Show)

mkBrokerServiceIdentity :: Text -> Either String BrokerServiceIdentity
mkBrokerServiceIdentity raw =
  boundedToken "broker service identity" 128 raw >>= pure . BrokerServiceIdentity

renderBrokerServiceIdentity :: BrokerServiceIdentity -> Text
renderBrokerServiceIdentity (BrokerServiceIdentity identity) = identity

newtype IdempotencyKey = IdempotencyKey Text
  deriving stock (Eq, Ord, Show)

mkIdempotencyKey :: Text -> Either String IdempotencyKey
mkIdempotencyKey raw =
  boundedToken "idempotency key" 128 raw >>= pure . IdempotencyKey

renderIdempotencyKey :: IdempotencyKey -> Text
renderIdempotencyKey (IdempotencyKey key) = key

newtype RequestDigest = RequestDigest Text
  deriving stock (Eq, Ord, Show)

-- | Request digests are lowercase hexadecimal SHA-256 strings.  Pinning the
-- representation prevents an idempotency key from being rebound through an
-- alternate textual digest encoding.
mkRequestDigest :: Text -> Either String RequestDigest
mkRequestDigest raw
  | Text.length raw /= 64 =
      Left "request digest must contain exactly 64 lowercase hexadecimal characters"
  | Text.all isLowerHex raw = Right (RequestDigest raw)
  | otherwise = Left "request digest must contain exactly 64 lowercase hexadecimal characters"
 where
  isLowerHex char = isDigit char || char >= 'a' && char <= 'f'

renderRequestDigest :: RequestDigest -> Text
renderRequestDigest (RequestDigest digest) = digest

-- | The canonical digest used by both the client and server over the exact
-- HTTP entity bytes.  Sharing this projection prevents an idempotency key from
-- being bound to subtly different JSON encodings at the two boundaries.
requestDigestForBytes :: ByteString -> RequestDigest
requestDigestForBytes bytes =
  case mkRequestDigest (Text.pack (concatMap renderByte (BS.unpack (SHA256.hash bytes)))) of
    Right digest -> digest
    Left err -> error ("SHA-256 rendering violated the request digest invariant: " ++ err)
 where
  renderByte :: Word8 -> String
  renderByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

data RequestMetadata = RequestMetadata
  { requestIdempotencyKey :: !IdempotencyKey
  , requestDigest :: !RequestDigest
  , requestCallerIdentity :: !BrokerServiceIdentity
  , requestCallerAddress :: !LoopbackAddress
  , requestContentLength :: !Natural
  , requestReceivedAt :: !MonotonicInstant
  , requestBudget :: !RemainingDuration
  }
  deriving stock (Eq, Show)

data BrokerRequest = BrokerRequest
  { brokerRequestOperation :: !BrokerOperationTag
  , brokerRequestMethod :: !HttpMethod
  , brokerRequestMetadata :: !RequestMetadata
  , brokerRequestSecret :: !(Maybe SecretPayload)
  }
  deriving stock (Eq, Show)

requestAbsoluteDeadline :: BrokerRequest -> Deadline
requestAbsoluteDeadline request =
  deadlineAtOffset
    (requestReceivedAt metadata)
    (requestBudget metadata)
 where
  metadata = brokerRequestMetadata request

requestCarriesSecret :: BrokerRequest -> Bool
requestCarriesSecret = maybe False (const True) . brokerRequestSecret

boundedToken :: String -> Int -> Text -> Either String Text
boundedToken label maximumLength raw
  | Text.null value = Left (label ++ " must not be empty")
  | Text.length value > maximumLength =
      Left (label ++ " exceeds " ++ show maximumLength ++ " characters")
  | Text.all isTokenCharacter value = Right value
  | otherwise = Left (label ++ " contains a forbidden character")
 where
  value = Text.strip raw
  isTokenCharacter char =
    isAsciiLower char
      || isAsciiUpper char
      || isDigit char
      || char `elem` ("-._:/@" :: String)
