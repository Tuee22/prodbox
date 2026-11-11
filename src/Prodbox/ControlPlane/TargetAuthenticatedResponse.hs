{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A bounded Target response envelope bound to the request and the signer's
-- declared rollout. The declaration is not physical identity attestation.
-- Key selection, HTTP, deadlines and replay admission remain caller-owned.
module Prodbox.ControlPlane.TargetAuthenticatedResponse
  ( TargetAuthenticatedResponseError (..)
  , signTargetAuthenticatedResponse
  , verifyTargetAuthenticatedResponse
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (authorityScopeText)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route (ControlPlaneRoute (TargetSecretTrustInstall))
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , targetAgentClusterIdentity
  , targetAgentIdentityText
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime))

data TargetAuthenticatedResponseError
  = TargetResponseInvalidLimit
  | TargetResponseRequestRefused
  | TargetResponseSignerRefused
  | TargetResponseBodyTooLarge
  | TargetResponseStatusInvalid
  | TargetResponseSigningFailed
  | TargetResponseFrameTooLarge
  | TargetResponseWireInvalid
  | TargetResponseNonCanonical
  | TargetResponseClaimsMismatch
  | TargetResponseSignatureInvalid
  deriving stock (Eq, Show)

data ResponseClaims = ResponseClaims !ByteString !ByteString !ByteString !Word !ByteString !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ResponseWire = ResponseWire !ResponseClaims !ByteString !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

responseDomain :: ByteString
responseDomain = "prodbox-target-epoch-response/v2"

-- Enough for fixed domain, three SHA-256 digests, a Word status, a bounded
-- signing generation, Ed25519 signature and canonical CBOR framing.
responseFrameOverhead :: Int
responseFrameOverhead = 512

validLimit :: Int -> Bool
validLimit limit = limit > 0 && limit <= maxBound - responseFrameOverhead

validStatus :: Word -> Bool
validStatus status = status >= 100 && status <= 599

responseClaims
  :: TargetAgentIdentity -> ByteString -> Word -> ByteString -> SigningKeyGeneration -> ResponseClaims
responseClaims agent requestDigest status body generation =
  ResponseClaims
    responseDomain
    (SHA256.hash (TextEncoding.encodeUtf8 (targetAgentIdentityText agent)))
    requestDigest
    status
    (SHA256.hash body)
    (fromIntegral (signingKeyGenerationValue generation))

-- | The server may sign only after the original Target trust request has been
-- authenticated. The caller still owns deadline checks and the role's replay
-- policy, including bounded signing and successful response publication.
signTargetAuthenticatedResponse
  :: (Monad m)
  => Int
  -> TargetAgentIdentity
  -> RequestSigningCapability m
  -> VerifiedControlPlaneRequest
  -> Word
  -> ByteString
  -> m (Either TargetAuthenticatedResponseError ByteString)
signTargetAuthenticatedResponse maximumBody agent signer request status body
  | not (validLimit maximumBody) = pure (Left TargetResponseInvalidLimit)
  | verifiedRequestRoute request /= TargetSecretTrustInstall
      || verifiedRequestCalleeRole request /= TargetSecretAgentRuntime
      || verifiedRequestCallerPrincipal request /= CallerService LifecycleAuthorityRuntime
      || targetAgentClusterIdentity agent /= authorityScopeText (verifiedRequestAuthorityScope request) =
      pure (Left TargetResponseRequestRefused)
  | requestSigningCapabilityPrincipal signer /= CallerService TargetSecretAgentRuntime =
      pure (Left TargetResponseSignerRefused)
  | not (validStatus status) = pure (Left TargetResponseStatusInvalid)
  | ByteString.length body > maximumBody = pure (Left TargetResponseBodyTooLarge)
  | otherwise = do
      let claims =
            responseClaims
              agent
              (verifiedRequestDigestBytes request)
              status
              body
              (requestSigningCapabilityGeneration signer)
      signed <-
        signCanonicalBytesWithRequestCapability signer (LazyByteString.toStrict (serialise claims))
      pure $ case signed of
        Left _ -> Left TargetResponseSigningFailed
        Right signature ->
          let encoded = LazyByteString.toStrict (serialise (ResponseWire claims body signature))
           in if ByteString.length encoded > maximumBody + responseFrameOverhead
                then Left TargetResponseFrameTooLarge
                else Right encoded

-- | The client must obtain the trusted Target key from an independently
-- authenticated, current registry and retain the exact request it sent. This
-- function does not claim that the registry or physical observation is fresh.
verifyTargetAuthenticatedResponse
  :: Int
  -> TargetAgentIdentity
  -> TrustedRequestKey
  -> SignedControlPlaneRequest
  -> ByteString
  -> Either TargetAuthenticatedResponseError (Word, ByteString)
verifyTargetAuthenticatedResponse maximumBody agent trusted request encoded = do
  unless (validLimit maximumBody) (Left TargetResponseInvalidLimit)
  unless
    (trustedRequestCallerPrincipal trusted == CallerService TargetSecretAgentRuntime)
    (Left TargetResponseSignerRefused)
  unless
    (ByteString.length encoded <= maximumBody + responseFrameOverhead)
    (Left TargetResponseFrameTooLarge)
  wire@( ResponseWire
           claims@(ResponseClaims domain agentDigest requestDigest status bodyDigest generation)
           body
           signatureBytes
         ) <-
    either
      (const (Left TargetResponseWireInvalid))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict encoded))
  unless (LazyByteString.toStrict (serialise wire) == encoded) (Left TargetResponseNonCanonical)
  unless (ByteString.length body <= maximumBody) (Left TargetResponseBodyTooLarge)
  unless (validStatus status) (Left TargetResponseStatusInvalid)
  let expectedDigest = SHA256.hash (LazyByteString.toStrict (encodeSignedControlPlaneRequest request))
  unless
    ( domain == responseDomain
        && agentDigest == SHA256.hash (TextEncoding.encodeUtf8 (targetAgentIdentityText agent))
        && requestDigest == expectedDigest
        && bodyDigest == SHA256.hash body
        && generation == fromIntegral (signingKeyGenerationValue (trustedRequestGeneration trusted))
    )
    (Left TargetResponseClaimsMismatch)
  public <- case Ed25519.publicKey (trustedRequestPublicKeyBytes trusted) of
    CryptoFailed _ -> Left TargetResponseSignatureInvalid
    CryptoPassed value -> Right value
  signature <- case Ed25519.signature signatureBytes of
    CryptoFailed _ -> Left TargetResponseSignatureInvalid
    CryptoPassed value -> Right value
  unless
    (Ed25519.verify public (LazyByteString.toStrict (serialise claims)) signature)
    (Left TargetResponseSignatureInvalid)
  pure (status, body)
