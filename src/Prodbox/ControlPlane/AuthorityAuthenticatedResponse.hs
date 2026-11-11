{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Opt-in response authentication for Authority promotion and registry reads.
-- The supplied key and the entire deadline/resource envelope remain owned by
-- the caller; this codec does not attest an Authority deployment.
module Prodbox.ControlPlane.AuthorityAuthenticatedResponse
  ( AuthorityAuthenticatedResponseError (..)
  , isAuthoritySignedObservation
  , signAuthorityAuthenticatedResponse
  , verifyAuthorityAuthenticatedResponse
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
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (trustedCallersForRoute)
import Prodbox.ControlPlane.AuthorityControlProtocol (isSignedEpochPromotionObservationForRole)
import Prodbox.ControlPlane.AuthorityPeerContext (isSignedAuthorityPeerContextRequest)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAuthorityPeerObserve, LifecycleMigrationApply)
  )
import Prodbox.ControlPlane.RpcAdmissionBirthWire
  ( rpcBirthSignedDescriptorRequest
  , rpcBirthSignedRegistryRequest
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthorityAuthenticatedResponseError
  = AuthorityResponseInvalidLimit
  | AuthorityResponseRequestRefused
  | AuthorityResponseSignerRefused
  | AuthorityResponseBodyTooLarge
  | AuthorityResponseStatusInvalid
  | AuthorityResponseSigningFailed
  | AuthorityResponseFrameTooLarge
  | AuthorityResponseWireInvalid
  | AuthorityResponseNonCanonical
  | AuthorityResponseClaimsMismatch
  | AuthorityResponseSignatureInvalid
  deriving stock (Eq, Show)

data Claims = Claims !ByteString !ByteString !Word !ByteString !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data Wire = Wire !Claims !ByteString !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

domain :: ByteString
domain = "prodbox-authority-observation-response/v1"

-- Fixed domain, two SHA-256 digests, status, generation, signature and CBOR.
frameOverhead :: Int
frameOverhead = 512

validLimit :: Int -> Bool
validLimit n = n > 0 && n <= maxBound - frameOverhead

validStatus :: Word -> Bool
validStatus status = status >= 100 && status <= 599

isAuthoritySignedObservation :: VerifiedControlPlaneRequest -> Bool
isAuthoritySignedObservation request =
  verifiedRequestCalleeRole request == LifecycleAuthorityRuntime
    && verifiedRequestCallerPrincipal request `elem` trustedCallersForRoute route
    && ( isSignedEpochPromotionObservationForRole LifecycleAuthorityRuntime route body
           || (route == LifecycleAuthorityPeerObserve && isSignedAuthorityPeerContextRequest body)
           || ( route == LifecycleMigrationApply
                  && body `elem` [rpcBirthSignedDescriptorRequest, rpcBirthSignedRegistryRequest]
                  && verifiedRequestCallerPrincipal request `elem` [CallerOperatorCli, CallerTestHarness]
              )
       )
 where
  route = verifiedRequestRoute request
  body = verifiedRequestBody request

claimsFor :: ByteString -> Word -> ByteString -> SigningKeyGeneration -> Claims
claimsFor requestDigest status body generation =
  Claims
    domain
    requestDigest
    status
    (SHA256.hash body)
    (fromIntegral (signingKeyGenerationValue generation))

signAuthorityAuthenticatedResponse
  :: (Monad m)
  => Int
  -> RequestSigningCapability m
  -> VerifiedControlPlaneRequest
  -> Word
  -> ByteString
  -> m (Either AuthorityAuthenticatedResponseError ByteString)
signAuthorityAuthenticatedResponse maximumBody signer request status body
  | not (validLimit maximumBody) = pure (Left AuthorityResponseInvalidLimit)
  | not (isAuthoritySignedObservation request) = pure (Left AuthorityResponseRequestRefused)
  | requestSigningCapabilityPrincipal signer /= CallerService LifecycleAuthorityRuntime =
      pure (Left AuthorityResponseSignerRefused)
  | not (validStatus status) = pure (Left AuthorityResponseStatusInvalid)
  | ByteString.length body > maximumBody = pure (Left AuthorityResponseBodyTooLarge)
  | otherwise = do
      let claims =
            claimsFor
              (verifiedRequestDigestBytes request)
              status
              body
              (requestSigningCapabilityGeneration signer)
      signed <-
        signCanonicalBytesWithRequestCapability signer (LazyByteString.toStrict (serialise claims))
      pure $ case signed of
        Left _ -> Left AuthorityResponseSigningFailed
        Right signature ->
          let encoded = LazyByteString.toStrict (serialise (Wire claims body signature))
           in if ByteString.length encoded > maximumBody + frameOverhead
                then Left AuthorityResponseFrameTooLarge
                else Right encoded

verifyAuthorityAuthenticatedResponse
  :: Int
  -> TrustedRequestKey
  -> SignedControlPlaneRequest
  -> ByteString
  -> Either AuthorityAuthenticatedResponseError (Word, ByteString)
verifyAuthorityAuthenticatedResponse maximumBody trusted request encoded = do
  unless (validLimit maximumBody) (Left AuthorityResponseInvalidLimit)
  unless
    (trustedRequestCallerPrincipal trusted == CallerService LifecycleAuthorityRuntime)
    (Left AuthorityResponseSignerRefused)
  unless
    (ByteString.length encoded <= maximumBody + frameOverhead)
    (Left AuthorityResponseFrameTooLarge)
  wire@(Wire claims@(Claims actualDomain requestDigest status bodyDigest generation) body signatureBytes) <-
    either
      (const (Left AuthorityResponseWireInvalid))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict encoded))
  unless (LazyByteString.toStrict (serialise wire) == encoded) (Left AuthorityResponseNonCanonical)
  unless (ByteString.length body <= maximumBody) (Left AuthorityResponseBodyTooLarge)
  unless (validStatus status) (Left AuthorityResponseStatusInvalid)
  let expectedDigest = SHA256.hash (LazyByteString.toStrict (encodeSignedControlPlaneRequest request))
  unless
    ( actualDomain == domain
        && requestDigest == expectedDigest
        && bodyDigest == SHA256.hash body
        && generation == fromIntegral (signingKeyGenerationValue (trustedRequestGeneration trusted))
    )
    (Left AuthorityResponseClaimsMismatch)
  public <- case Ed25519.publicKey (trustedRequestPublicKeyBytes trusted) of
    CryptoFailed _ -> Left AuthorityResponseSignatureInvalid
    CryptoPassed value -> Right value
  signature <- case Ed25519.signature signatureBytes of
    CryptoFailed _ -> Left AuthorityResponseSignatureInvalid
    CryptoPassed value -> Right value
  unless
    (Ed25519.verify public (LazyByteString.toStrict (serialise claims)) signature)
    (Left AuthorityResponseSignatureInvalid)
  pure (status, body)
