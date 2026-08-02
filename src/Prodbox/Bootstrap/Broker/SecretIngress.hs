{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Length-delimited, exact-binding stdin protocol for a one-shot Bootstrap
-- Broker secret worker.
--
-- Kubernetes exec/attach authenticates and authorizes the transport to the
-- named worker Pod. This frame additionally binds the opaque secret bytes to
-- the exact Pod UID, session/accessor, operation, durable fence, request,
-- storage generation, and non-extendable operation deadline. The decoder
-- accepts one canonical CBOR frame under a caller-supplied payload bound and
-- never exposes the bytes through 'Show'.
module Prodbox.Bootstrap.Broker.SecretIngress
  ( SecretIngressError (..)
  , encodeSecretIngressFrame
  , decodeSecretIngressFrame
  , readSecretIngressFrame
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fence
  ( bootstrapFenceGenerationValue
  )
import Prodbox.Bootstrap.Broker.PgpBoundary (withPgpSecretPayloadBytes)
import Prodbox.Bootstrap.Broker.Request
  ( SecretPayload
  , mkSecretPayload
  , renderRequestDigest
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( SecretFreeWorkerRequest
  , SecretWorkerOperation (..)
  , renderWorkerPodUid
  , renderWorkerSessionAccessor
  , renderWorkerSessionId
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestOperation
  , secretWorkerRequestOperationDeadline
  , secretWorkerRequestOwnerNonce
  , secretWorkerRequestPodUid
  , secretWorkerRequestSessionAccessor
  , secretWorkerRequestSessionId
  , secretWorkerRequestStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Types
  ( renderArtifactDigest
  , renderVaultStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock (operationDeadlineMicros)
import Prodbox.Lifecycle.Lease (ownerNonceText)
import System.IO (Handle)

data SecretIngressError
  = SecretIngressPayloadTooLarge !Natural !Natural
  | SecretIngressFrameTooLarge !Natural
  | SecretIngressTruncated
  | SecretIngressDecodeFailed
  | SecretIngressNonCanonical
  | SecretIngressSchemaMismatch !Natural
  | SecretIngressBindingMismatch
  | SecretIngressPayloadInvalid
  deriving stock (Eq, Show)

data SecretIngressDto = SecretIngressDto
  { ingressSchemaVersion :: !Natural
  , ingressOperationTag :: !Natural
  , ingressPodUid :: !Text
  , ingressSessionId :: !Text
  , ingressSessionAccessor :: !Text
  , ingressFenceGeneration :: !Natural
  , ingressOwnerNonce :: !Text
  , ingressActionDigest :: !Text
  , ingressRequestDigest :: !Text
  , ingressStorageGeneration :: !Text
  , ingressOperationDeadlineMicros :: !Natural
  , ingressSecretPayload :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

secretIngressSchemaVersion :: Natural
secretIngressSchemaVersion = 1

maximumSecretIngressFrameBytes :: Natural
maximumSecretIngressFrameBytes = 128 * 1024

encodeSecretIngressFrame
  :: Natural
  -> SecretFreeWorkerRequest
  -> SecretPayload
  -> Either SecretIngressError ByteString
encodeSecretIngressFrame maximumPayload request payload =
  withPgpSecretPayloadBytes payload $ \payloadBytes -> do
    let actualPayload = fromIntegral (ByteString.length payloadBytes)
    if actualPayload > maximumPayload
      then Left (SecretIngressPayloadTooLarge maximumPayload actualPayload)
      else do
        let encoded = LazyByteString.toStrict (serialise (dtoFor request payloadBytes))
            encodedLength = fromIntegral (ByteString.length encoded)
        ( if (encodedLength > maximumSecretIngressFrameBytes)
            || (encodedLength > fromIntegral (maxBound :: Word32))
            then Left (SecretIngressFrameTooLarge encodedLength)
            else Right (word32Prefix (fromIntegral encodedLength) <> encoded)
          )

decodeSecretIngressFrame
  :: Natural
  -> SecretFreeWorkerRequest
  -> ByteString
  -> Either SecretIngressError SecretPayload
decodeSecretIngressFrame maximumPayload request framed = do
  (declaredLength, encoded) <- splitFrame framed
  let actualLength = ByteString.length encoded
  if declaredLength /= fromIntegral actualLength
    then Left SecretIngressTruncated
    else
      if fromIntegral actualLength > maximumSecretIngressFrameBytes
        then Left (SecretIngressFrameTooLarge (fromIntegral actualLength))
        else do
          dto <-
            either
              (const (Left SecretIngressDecodeFailed))
              Right
              (deserialiseOrFail (LazyByteString.fromStrict encoded))
          if LazyByteString.toStrict (serialise dto) /= encoded
            then Left SecretIngressNonCanonical
            else validateDto maximumPayload request dto

readSecretIngressFrame
  :: Natural
  -> SecretFreeWorkerRequest
  -> Handle
  -> IO (Either SecretIngressError SecretPayload)
readSecretIngressFrame maximumPayload request handle = do
  prefix <- ByteString.hGet handle 4
  if ByteString.length prefix /= 4
    then pure (Left SecretIngressTruncated)
    else do
      let declaredLength = prefixWord32 prefix
      if fromIntegral declaredLength > maximumSecretIngressFrameBytes
        then pure (Left (SecretIngressFrameTooLarge (fromIntegral declaredLength)))
        else do
          body <- ByteString.hGet handle (fromIntegral declaredLength)
          pure (decodeSecretIngressFrame maximumPayload request (prefix <> body))

dtoFor :: SecretFreeWorkerRequest -> ByteString -> SecretIngressDto
dtoFor request payload =
  SecretIngressDto
    { ingressSchemaVersion = secretIngressSchemaVersion
    , ingressOperationTag = operationTag (secretWorkerRequestOperation request)
    , ingressPodUid = renderWorkerPodUid (secretWorkerRequestPodUid request)
    , ingressSessionId = renderWorkerSessionId (secretWorkerRequestSessionId request)
    , ingressSessionAccessor =
        renderWorkerSessionAccessor (secretWorkerRequestSessionAccessor request)
    , ingressFenceGeneration =
        bootstrapFenceGenerationValue (secretWorkerRequestFenceGeneration request)
    , ingressOwnerNonce = ownerNonceText (secretWorkerRequestOwnerNonce request)
    , ingressActionDigest = renderArtifactDigest (secretWorkerRequestActionDigest request)
    , ingressRequestDigest = renderRequestDigest (secretWorkerRequestDigest request)
    , ingressStorageGeneration =
        renderVaultStorageGeneration (secretWorkerRequestStorageGeneration request)
    , ingressOperationDeadlineMicros =
        operationDeadlineMicros (secretWorkerRequestOperationDeadline request)
    , ingressSecretPayload = payload
    }

validateDto
  :: Natural
  -> SecretFreeWorkerRequest
  -> SecretIngressDto
  -> Either SecretIngressError SecretPayload
validateDto maximumPayload request dto
  | ingressSchemaVersion dto /= secretIngressSchemaVersion =
      Left (SecretIngressSchemaMismatch (ingressSchemaVersion dto))
  | clearPayload dto /= clearPayload (dtoFor request ByteString.empty) =
      Left SecretIngressBindingMismatch
  | actualPayload > maximumPayload =
      Left (SecretIngressPayloadTooLarge maximumPayload actualPayload)
  | otherwise =
      either
        (const (Left SecretIngressPayloadInvalid))
        Right
        (mkSecretPayload maximumPayload (ingressSecretPayload dto))
 where
  actualPayload = fromIntegral (ByteString.length (ingressSecretPayload dto))
  clearPayload value = value {ingressSecretPayload = ByteString.empty}

operationTag :: SecretWorkerOperation -> Natural
operationTag operation = case operation of
  SecretWorkerPrepareInitialization -> 0
  SecretWorkerResumeInitialization -> 1
  SecretWorkerInitialize -> 2
  SecretWorkerFinalizeInitialization -> 3
  SecretWorkerUnseal -> 4
  SecretWorkerRotateUnlockBundle -> 5
  SecretWorkerRotateTransitKey -> 6
  SecretWorkerCompleteGeneratedRoot -> 7

splitFrame :: ByteString -> Either SecretIngressError (Word32, ByteString)
splitFrame framed
  | ByteString.length framed < 4 = Left SecretIngressTruncated
  | otherwise = Right (prefixWord32 prefix, body)
 where
  (prefix, body) = ByteString.splitAt 4 framed

word32Prefix :: Word32 -> ByteString
word32Prefix value =
  ByteString.pack
    [ fromIntegral ((value `shiftR` 24) .&. 0xff)
    , fromIntegral ((value `shiftR` 16) .&. 0xff)
    , fromIntegral ((value `shiftR` 8) .&. 0xff)
    , fromIntegral (value .&. 0xff)
    ]

prefixWord32 :: ByteString -> Word32
prefixWord32 bytes =
  foldl
    (\acc byte -> acc * 256 + fromIntegral byte)
    0
    (ByteString.unpack bytes)
