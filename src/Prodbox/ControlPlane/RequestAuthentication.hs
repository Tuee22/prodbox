{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure authentication framing for requests between the physically separate
-- control-plane services.
--
-- The envelope is deliberately independent of the HTTP client and server.  A
-- caller signs one canonical set of claims and the exact SHA-256 digest of the
-- enclosed canonical role request.  A callee verifies those claims against its
-- locally observed route, role, authority scope, active epoch, trusted caller
-- key, request metadata, and authority clock before exposing the enclosed body.
--
-- Replay ownership is intentionally outside this pure boundary.  A production
-- dispatcher must durably reserve the verified
-- @(scope, epoch, caller, key-generation, nonce)@ before running an effect and
-- recover an exact duplicate from the recorded request digest/result.
module Prodbox.ControlPlane.RequestAuthentication
  ( -- * Caller identities
    CallerPrincipal (..)
  , allCallerPrincipals
  , callerPrincipalCode
  , callerPrincipalFromCode

    -- * Stable nonce and signing-key generation
  , RequestNonce
  , RequestNonceError (..)
  , mkRequestNonce
  , requestNonceBytes
  , SigningKeyGeneration
  , SigningKeyGenerationError (..)
  , mkSigningKeyGeneration
  , signingKeyGenerationValue

    -- * Signing and trust identities
  , RequestSigner
  , RequestKeyError (..)
  , mkRequestSigner
  , requestSignerPublicKeyBytes
  , RequestSigningCapability
  , RequestSigningCapabilityError (..)
  , mkRequestSigningCapability
  , localRequestSigningCapability
  , requestSigningCapabilityPrincipal
  , requestSigningCapabilityGeneration
  , requestSigningCapabilityPublicKeyBytes
  , signCanonicalBytesWithRequestCapability
  , TrustedRequestKey
  , mkTrustedRequestKey
  , trustedRequestKeyFromSigner
  , trustedRequestCallerPrincipal
  , trustedRequestGeneration
  , trustedRequestPublicKeyBytes

    -- * Canonical signed envelope
  , currentRequestAuthenticationSchema
  , RequestBindingError (..)
  , SignedControlPlaneRequest
  , signControlPlaneRequest
  , signControlPlaneRequestWith
  , encodeSignedControlPlaneRequest

    -- * Verification
  , RequestVerificationContext
  , mkRequestVerificationContext
  , RequestAuthenticationError (..)
  , VerifiedControlPlaneRequest
  , decodeAndVerifyControlPlaneRequest
  , verifiedRequestRoute
  , verifiedRequestCallerPrincipal
  , verifiedRequestCalleeRole
  , verifiedRequestAuthorityScope
  , verifiedRequestAuthorityEpoch
  , verifiedRequestDeadline
  , verifiedRequestNonce
  , verifiedRequestSigningKeyGeneration
  , verifiedRequestDigestBytes
  , verifiedRequestBody
  , VerifiedCallerSlot
  , verifiedRequestCallerSlot
  , verifiedCallerSlotPrincipal
  , verifiedCallerSlotKeyGeneration
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (..)
  , allCallerPrincipals
  , callerPrincipalCode
  , callerPrincipalFromCode
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , CoordinateError
  , authorityScopeText
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  , controlPlaneRouteRole
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , addAuthorityDuration
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Runtime.Role (RuntimeRole (..))

minimumRequestNonceBytes :: Int
minimumRequestNonceBytes = 16

maximumRequestNonceBytes :: Int
maximumRequestNonceBytes = 64

newtype RequestNonce = RequestNonce ByteString
  deriving stock (Eq, Ord, Show)

data RequestNonceError
  = RequestNonceTooShort !Int !Int
  | RequestNonceTooLong !Int !Int
  deriving stock (Eq, Show)

mkRequestNonce :: ByteString -> Either RequestNonceError RequestNonce
mkRequestNonce bytes
  | observed < minimumRequestNonceBytes =
      Left (RequestNonceTooShort observed minimumRequestNonceBytes)
  | observed > maximumRequestNonceBytes =
      Left (RequestNonceTooLong observed maximumRequestNonceBytes)
  | otherwise = Right (RequestNonce bytes)
 where
  observed = ByteString.length bytes

requestNonceBytes :: RequestNonce -> ByteString
requestNonceBytes (RequestNonce bytes) = bytes

newtype SigningKeyGeneration = SigningKeyGeneration Natural
  deriving stock (Eq, Ord, Show)

data SigningKeyGenerationError
  = SigningKeyGenerationMustBePositive
  deriving stock (Eq, Show)

mkSigningKeyGeneration
  :: Natural -> Either SigningKeyGenerationError SigningKeyGeneration
mkSigningKeyGeneration generation
  | generation == 0 = Left SigningKeyGenerationMustBePositive
  | otherwise = Right (SigningKeyGeneration generation)

signingKeyGenerationValue :: SigningKeyGeneration -> Natural
signingKeyGenerationValue (SigningKeyGeneration generation) = generation

-- | Private request-signing identity.  It has no 'Show', 'Eq', or serialization
-- instance, so private key bytes cannot enter an envelope or diagnostic by
-- accident.
data RequestSigner = RequestSigner
  { requestSignerPrincipal :: !CallerPrincipal
  , requestSignerGeneration :: !SigningKeyGeneration
  , requestSignerSecretKey :: !Ed25519.SecretKey
  }

data RequestKeyError
  = RequestSecretKeyInvalid
  | RequestPublicKeyInvalid
  deriving stock (Eq, Show)

mkRequestSigner
  :: CallerPrincipal
  -> SigningKeyGeneration
  -> ByteString
  -> Either RequestKeyError RequestSigner
mkRequestSigner principal generation bytes = case Ed25519.secretKey bytes of
  CryptoFailed _ -> Left RequestSecretKeyInvalid
  CryptoPassed key ->
    Right
      RequestSigner
        { requestSignerPrincipal = principal
        , requestSignerGeneration = generation
        , requestSignerSecretKey = key
        }

requestSignerPublicKeyBytes :: RequestSigner -> ByteString
requestSignerPublicKeyBytes signer =
  ByteArray.convert (Ed25519.toPublic (requestSignerSecretKey signer))

-- | One public verification key pinned to exactly one caller principal and key
-- generation.  Selection/rotation of this value is configuration ownership,
-- not part of request verification.
data TrustedRequestKey = TrustedRequestKey
  { trustedRequestCallerPrincipal :: !CallerPrincipal
  , trustedRequestGeneration :: !SigningKeyGeneration
  , trustedRequestPublicKey :: !Ed25519.PublicKey
  }

mkTrustedRequestKey
  :: CallerPrincipal
  -> SigningKeyGeneration
  -> ByteString
  -> Either RequestKeyError TrustedRequestKey
mkTrustedRequestKey principal generation bytes = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left RequestPublicKeyInvalid
  CryptoPassed publicKey ->
    Right
      TrustedRequestKey
        { trustedRequestCallerPrincipal = principal
        , trustedRequestGeneration = generation
        , trustedRequestPublicKey = publicKey
        }

trustedRequestKeyFromSigner :: RequestSigner -> TrustedRequestKey
trustedRequestKeyFromSigner signer =
  TrustedRequestKey
    { trustedRequestCallerPrincipal = requestSignerPrincipal signer
    , trustedRequestGeneration = requestSignerGeneration signer
    , trustedRequestPublicKey = Ed25519.toPublic (requestSignerSecretKey signer)
    }

trustedRequestPublicKeyBytes :: TrustedRequestKey -> ByteString
trustedRequestPublicKeyBytes = ByteArray.convert . trustedRequestPublicKey

-- | An effectful request signer whose private half remains behind a capability
-- boundary.  Production constructs this value from one pinned Vault Transit
-- Ed25519 generation; pure tests use 'localRequestSigningCapability'.  The
-- public key is retained only so every returned signature is verified locally
-- before it can enter a control-plane frame.
data RequestSigningCapability m = RequestSigningCapability
  { requestSigningCapabilityPrincipal :: !CallerPrincipal
  , requestSigningCapabilityGeneration :: !SigningKeyGeneration
  , requestSigningCapabilityPublicKey :: !Ed25519.PublicKey
  , runRequestSigningCapability :: ByteString -> m (Either Text ByteString)
  }

data RequestSigningCapabilityError
  = RequestSigningCapabilityPublicKeyInvalid
  | RequestSigningCapabilitySignatureInvalid
  | RequestSigningCapabilityAuthenticationFailed
  | RequestSigningCapabilityUnavailable !Text
  deriving stock (Eq, Show)

-- | Construct a signer from a public generation and an opaque signing effect.
-- The effect receives only canonical claim bytes and can never inspect or
-- alter the enclosed request body independently of its signed digest.
mkRequestSigningCapability
  :: CallerPrincipal
  -> SigningKeyGeneration
  -> ByteString
  -> (ByteString -> m (Either Text ByteString))
  -> Either RequestSigningCapabilityError (RequestSigningCapability m)
mkRequestSigningCapability principal generation publicBytes signBytes =
  case Ed25519.publicKey publicBytes of
    CryptoFailed _ -> Left RequestSigningCapabilityPublicKeyInvalid
    CryptoPassed publicKey ->
      Right
        RequestSigningCapability
          { requestSigningCapabilityPrincipal = principal
          , requestSigningCapabilityGeneration = generation
          , requestSigningCapabilityPublicKey = publicKey
          , runRequestSigningCapability = signBytes
          }

requestSigningCapabilityPublicKeyBytes :: RequestSigningCapability m -> ByteString
requestSigningCapabilityPublicKeyBytes =
  ByteArray.convert . requestSigningCapabilityPublicKey

-- | Sign arbitrary canonical bytes through the same opaque Transit-backed
-- capability used for request envelopes, then verify the returned signature
-- against the capability's pinned public key before releasing it.  This is the
-- narrow bridge used by the Lifecycle Authority to sign committed Provider
-- intents; it exposes neither a private key nor a generic Vault capability.
signCanonicalBytesWithRequestCapability
  :: (Monad m)
  => RequestSigningCapability m
  -> ByteString
  -> m (Either RequestSigningCapabilityError ByteString)
signCanonicalBytesWithRequestCapability capability bytes = do
  signatureResult <- runRequestSigningCapability capability bytes
  pure $ do
    signatureBytes <-
      either (Left . RequestSigningCapabilityUnavailable) Right signatureResult
    signature <- case Ed25519.signature signatureBytes of
      CryptoFailed _ -> Left RequestSigningCapabilitySignatureInvalid
      CryptoPassed decoded -> Right decoded
    if Ed25519.verify (requestSigningCapabilityPublicKey capability) bytes signature
      then Right signatureBytes
      else Left RequestSigningCapabilityAuthenticationFailed

-- | Test-only/local adapter.  Production code never calls this constructor;
-- it exists so the pure authentication suites can retain deterministic local
-- Ed25519 seeds without teaching the runtime about raw private key bytes.
localRequestSigningCapability
  :: (Applicative m) => RequestSigner -> RequestSigningCapability m
localRequestSigningCapability signer =
  RequestSigningCapability
    { requestSigningCapabilityPrincipal = requestSignerPrincipal signer
    , requestSigningCapabilityGeneration = requestSignerGeneration signer
    , requestSigningCapabilityPublicKey = publicKey
    , runRequestSigningCapability = \bytes ->
        pure
          ( Right
              ( ByteArray.convert
                  (Ed25519.sign secretKey publicKey bytes)
              )
          )
    }
 where
  secretKey = requestSignerSecretKey signer
  publicKey = Ed25519.toPublic secretKey

-- | Stable domain separator carried in, and signed with, every envelope.
requestAuthenticationProtocol :: Text
requestAuthenticationProtocol = "prodbox-control-plane-request"

currentRequestAuthenticationSchema :: Word
currentRequestAuthenticationSchema = 1

data RequestClaims = RequestClaims
  { requestClaimsRoute :: !ControlPlaneRoute
  , requestClaimsCallerPrincipal :: !CallerPrincipal
  , requestClaimsCalleeRole :: !RuntimeRole
  , requestClaimsAuthorityScope :: !AuthorityScope
  , requestClaimsAuthorityEpoch :: !AuthorityEpoch
  , requestClaimsDeadline :: !AuthorityTime
  , requestClaimsNonce :: !RequestNonce
  , requestClaimsSigningKeyGeneration :: !SigningKeyGeneration
  , requestClaimsBodyDigest :: !ByteString
  }
  deriving stock (Eq, Show)

newtype RequestSignature = RequestSignature ByteString
  deriving stock (Eq, Show)

data SignedControlPlaneRequest = SignedControlPlaneRequest
  { signedRequestClaims :: !RequestClaims
  , signedRequestBody :: !ByteString
  , signedRequestSignature :: !RequestSignature
  }
  deriving stock (Eq, Show)

data RequestBindingError
  = RequestRouteCalleeMismatch !ControlPlaneRoute !RuntimeRole !RuntimeRole
  deriving stock (Eq, Show)

-- | Sign a canonical request.  The route owner is checked before signing, so a
-- caller cannot mint an internally inconsistent route/callee claim.
signControlPlaneRequest
  :: RequestSigner
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> RequestNonce
  -> ByteString
  -> Either RequestBindingError SignedControlPlaneRequest
signControlPlaneRequest signer route callee scope epoch deadline nonce body
  | controlPlaneRouteRole route /= callee =
      Left
        ( RequestRouteCalleeMismatch
            route
            callee
            (controlPlaneRouteRole route)
        )
  | otherwise =
      Right
        SignedControlPlaneRequest
          { signedRequestClaims = claims
          , signedRequestBody = body
          , signedRequestSignature = RequestSignature signatureBytes
          }
 where
  claims =
    RequestClaims
      { requestClaimsRoute = route
      , requestClaimsCallerPrincipal = requestSignerPrincipal signer
      , requestClaimsCalleeRole = callee
      , requestClaimsAuthorityScope = scope
      , requestClaimsAuthorityEpoch = epoch
      , requestClaimsDeadline = deadline
      , requestClaimsNonce = nonce
      , requestClaimsSigningKeyGeneration = requestSignerGeneration signer
      , requestClaimsBodyDigest = SHA256.hash body
      }
  secretKey = requestSignerSecretKey signer
  signature =
    Ed25519.sign
      secretKey
      (Ed25519.toPublic secretKey)
      (canonicalRequestClaims claims)
  signatureBytes = ByteArray.convert signature

-- | Effectful production signing path.  Claims are assembled exactly once,
-- signed behind the supplied capability, and the returned signature is checked
-- against the capability's pinned public generation before framing.
signControlPlaneRequestWith
  :: (Monad m)
  => RequestSigningCapability m
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> RequestNonce
  -> ByteString
  -> m
       ( Either
           (Either RequestBindingError RequestSigningCapabilityError)
           SignedControlPlaneRequest
       )
signControlPlaneRequestWith capability route callee scope epoch deadline nonce body
  | controlPlaneRouteRole route /= callee =
      pure
        ( Left
            ( Left
                ( RequestRouteCalleeMismatch
                    route
                    callee
                    (controlPlaneRouteRole route)
                )
            )
        )
  | otherwise = do
      signatureResult <- signCanonicalBytesWithRequestCapability capability claimsBytes
      pure $ do
        signatureBytes <-
          either
            (Left . Right)
            Right
            signatureResult
        Right
          SignedControlPlaneRequest
            { signedRequestClaims = claims
            , signedRequestBody = body
            , signedRequestSignature = RequestSignature signatureBytes
            }
 where
  claims =
    RequestClaims
      { requestClaimsRoute = route
      , requestClaimsCallerPrincipal = requestSigningCapabilityPrincipal capability
      , requestClaimsCalleeRole = callee
      , requestClaimsAuthorityScope = scope
      , requestClaimsAuthorityEpoch = epoch
      , requestClaimsDeadline = deadline
      , requestClaimsNonce = nonce
      , requestClaimsSigningKeyGeneration =
          requestSigningCapabilityGeneration capability
      , requestClaimsBodyDigest = SHA256.hash body
      }
  claimsBytes = canonicalRequestClaims claims

-- The wire representation deliberately uses only stable primitive projections.
-- RuntimeRole and ControlPlaneRoute have no orphan Serialise instances; their
-- explicit codes below are the compatibility contract and every constructor is
-- handled by a named arm.
data RequestClaimsWire = RequestClaimsWire
  { wireRequestProtocol :: !Text
  , wireRequestSchema :: !Word
  , wireRequestRoute :: !Word
  , wireRequestCallerPrincipal :: !Word
  , wireRequestCalleeRole :: !Word
  , wireRequestAuthorityScope :: !Text
  , wireRequestAuthorityEpoch :: !Natural
  , wireRequestDeadlineMicros :: !Natural
  , wireRequestNonce :: !ByteString
  , wireRequestSigningKeyGeneration :: !Natural
  , wireRequestBodyDigest :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SignedControlPlaneRequestWire = SignedControlPlaneRequestWire
  { wireSignedRequestClaims :: !RequestClaimsWire
  , wireSignedRequestBody :: !ByteString
  , wireSignedRequestSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeSignedControlPlaneRequest :: SignedControlPlaneRequest -> LazyByteString.ByteString
encodeSignedControlPlaneRequest = serialise . signedRequestToWire

signedRequestToWire :: SignedControlPlaneRequest -> SignedControlPlaneRequestWire
signedRequestToWire request =
  SignedControlPlaneRequestWire
    { wireSignedRequestClaims = claimsToWire (signedRequestClaims request)
    , wireSignedRequestBody = signedRequestBody request
    , wireSignedRequestSignature =
        case signedRequestSignature request of
          RequestSignature bytes -> bytes
    }

claimsToWire :: RequestClaims -> RequestClaimsWire
claimsToWire claims =
  RequestClaimsWire
    { wireRequestProtocol = requestAuthenticationProtocol
    , wireRequestSchema = currentRequestAuthenticationSchema
    , wireRequestRoute = routeCode (requestClaimsRoute claims)
    , wireRequestCallerPrincipal =
        callerPrincipalCode (requestClaimsCallerPrincipal claims)
    , wireRequestCalleeRole = runtimeRoleCode (requestClaimsCalleeRole claims)
    , wireRequestAuthorityScope = authorityScopeText (requestClaimsAuthorityScope claims)
    , wireRequestAuthorityEpoch = authorityEpochValue (requestClaimsAuthorityEpoch claims)
    , wireRequestDeadlineMicros = authorityTimeMicros (requestClaimsDeadline claims)
    , wireRequestNonce = requestNonceBytes (requestClaimsNonce claims)
    , wireRequestSigningKeyGeneration =
        signingKeyGenerationValue (requestClaimsSigningKeyGeneration claims)
    , wireRequestBodyDigest = requestClaimsBodyDigest claims
    }

canonicalRequestClaims :: RequestClaims -> ByteString
canonicalRequestClaims = LazyByteString.toStrict . serialise . claimsToWire

data RequestVerificationContext = RequestVerificationContext
  { verificationTrustedKey :: !TrustedRequestKey
  , verificationExpectedRoute :: !ControlPlaneRoute
  , verificationExpectedCalleeRole :: !RuntimeRole
  , verificationExpectedAuthorityScope :: !AuthorityScope
  , verificationExpectedAuthorityEpoch :: !AuthorityEpoch
  , verificationExpectedDeadline :: !AuthorityTime
  , verificationExpectedNonce :: !RequestNonce
  , verificationAuthorityNow :: !AuthorityTime
  , verificationMaximumLifetime :: !AuthorityDuration
  }

mkRequestVerificationContext
  :: TrustedRequestKey
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> RequestNonce
  -> AuthorityTime
  -> AuthorityDuration
  -> Either RequestBindingError RequestVerificationContext
mkRequestVerificationContext trustedKey route callee scope epoch deadline nonce now maximumLifetime
  | controlPlaneRouteRole route /= callee =
      Left
        ( RequestRouteCalleeMismatch
            route
            callee
            (controlPlaneRouteRole route)
        )
  | otherwise =
      Right
        RequestVerificationContext
          { verificationTrustedKey = trustedKey
          , verificationExpectedRoute = route
          , verificationExpectedCalleeRole = callee
          , verificationExpectedAuthorityScope = scope
          , verificationExpectedAuthorityEpoch = epoch
          , verificationExpectedDeadline = deadline
          , verificationExpectedNonce = nonce
          , verificationAuthorityNow = now
          , verificationMaximumLifetime = maximumLifetime
          }

data RequestAuthenticationError
  = RequestEnvelopeTooLarge
  | RequestEnvelopeInvalid
  | RequestEnvelopeNonCanonical
  | RequestProtocolMismatch
  | RequestSchemaUnsupported !Word
  | RequestRouteIdentityInvalid !Word
  | RequestCallerPrincipalInvalid !Word
  | RequestCalleeRoleInvalid !Word
  | RequestAuthorityScopeInvalid !CoordinateError
  | RequestAuthorityEpochInvalid
  | RequestNonceSemanticInvalid !RequestNonceError
  | RequestSigningKeyGenerationSemanticInvalid !SigningKeyGenerationError
  | RequestBodyDigestWidthInvalid !Int !Int
  | RequestRouteCalleeBindingInvalid !ControlPlaneRoute !RuntimeRole !RuntimeRole
  | RequestSignatureInvalid
  | RequestAuthenticationFailed
  | RequestCallerPrincipalMismatch !CallerPrincipal !CallerPrincipal
  | RequestCalleeRoleMismatch !RuntimeRole !RuntimeRole
  | RequestRouteMismatch !ControlPlaneRoute !ControlPlaneRoute
  | RequestAuthorityScopeMismatch !AuthorityScope !AuthorityScope
  | RequestAuthorityEpochMismatch !AuthorityEpoch !AuthorityEpoch
  | RequestDeadlineMismatch !AuthorityTime !AuthorityTime
  | RequestNonceMismatch !RequestNonce !RequestNonce
  | RequestSigningKeyGenerationMismatch !SigningKeyGeneration !SigningKeyGeneration
  | RequestDeadlineExpired !AuthorityTime !AuthorityTime
  | RequestDeadlineExceedsMaximumLifetime !AuthorityTime !AuthorityTime
  | RequestBodyDigestMismatch
  deriving stock (Eq, Show)

newtype VerifiedControlPlaneRequest = VerifiedControlPlaneRequest SignedControlPlaneRequest
  deriving stock (Eq, Show)

-- | Decode and authenticate one complete request.  Canonical framing and all
-- semantic validation precede authentication; no enclosed role body is exposed
-- unless the signature and every locally expected binding agree.
decodeAndVerifyControlPlaneRequest
  :: Int
  -> RequestVerificationContext
  -> LazyByteString.ByteString
  -> Either RequestAuthenticationError VerifiedControlPlaneRequest
decodeAndVerifyControlPlaneRequest maximumBytes context bytes
  | maximumBytes < 0 = Left RequestEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left RequestEnvelopeTooLarge
  | otherwise = do
      wire <- case deserialiseOrFail bytes of
        Left _ -> Left RequestEnvelopeInvalid
        Right decoded -> Right decoded
      if serialise wire == bytes
        then pure ()
        else Left RequestEnvelopeNonCanonical
      request <- requestFromWire wire
      verifyRequest context request

requestFromWire
  :: SignedControlPlaneRequestWire
  -> Either RequestAuthenticationError SignedControlPlaneRequest
requestFromWire wire = do
  claims <- claimsFromWire (wireSignedRequestClaims wire)
  pure
    SignedControlPlaneRequest
      { signedRequestClaims = claims
      , signedRequestBody = wireSignedRequestBody wire
      , signedRequestSignature = RequestSignature (wireSignedRequestSignature wire)
      }

claimsFromWire :: RequestClaimsWire -> Either RequestAuthenticationError RequestClaims
claimsFromWire wire = do
  if wireRequestProtocol wire == requestAuthenticationProtocol
    then pure ()
    else Left RequestProtocolMismatch
  if wireRequestSchema wire == currentRequestAuthenticationSchema
    then pure ()
    else Left (RequestSchemaUnsupported (wireRequestSchema wire))
  route <-
    maybe
      (Left (RequestRouteIdentityInvalid (wireRequestRoute wire)))
      Right
      (routeFromCode (wireRequestRoute wire))
  caller <-
    maybe
      (Left (RequestCallerPrincipalInvalid (wireRequestCallerPrincipal wire)))
      Right
      (callerPrincipalFromCode (wireRequestCallerPrincipal wire))
  callee <-
    maybe
      (Left (RequestCalleeRoleInvalid (wireRequestCalleeRole wire)))
      Right
      (runtimeRoleFromCode (wireRequestCalleeRole wire))
  scope <-
    either
      (Left . RequestAuthorityScopeInvalid)
      Right
      (mkAuthorityScope (wireRequestAuthorityScope wire))
  epoch <-
    maybe
      (Left RequestAuthorityEpochInvalid)
      Right
      (authorityEpochFromValue (wireRequestAuthorityEpoch wire))
  nonce <-
    either
      (Left . RequestNonceSemanticInvalid)
      Right
      (mkRequestNonce (wireRequestNonce wire))
  generation <-
    either
      (Left . RequestSigningKeyGenerationSemanticInvalid)
      Right
      (mkSigningKeyGeneration (wireRequestSigningKeyGeneration wire))
  let digest = wireRequestBodyDigest wire
      expectedDigestWidth = 32
  if ByteString.length digest == expectedDigestWidth
    then pure ()
    else
      Left
        ( RequestBodyDigestWidthInvalid
            (ByteString.length digest)
            expectedDigestWidth
        )
  if controlPlaneRouteRole route == callee
    then pure ()
    else
      Left
        ( RequestRouteCalleeBindingInvalid
            route
            callee
            (controlPlaneRouteRole route)
        )
  pure
    RequestClaims
      { requestClaimsRoute = route
      , requestClaimsCallerPrincipal = caller
      , requestClaimsCalleeRole = callee
      , requestClaimsAuthorityScope = scope
      , requestClaimsAuthorityEpoch = epoch
      , requestClaimsDeadline = authorityTimeFromMicros (wireRequestDeadlineMicros wire)
      , requestClaimsNonce = nonce
      , requestClaimsSigningKeyGeneration = generation
      , requestClaimsBodyDigest = digest
      }

verifyRequest
  :: RequestVerificationContext
  -> SignedControlPlaneRequest
  -> Either RequestAuthenticationError VerifiedControlPlaneRequest
verifyRequest context request = do
  let claims = signedRequestClaims request
      trusted = verificationTrustedKey context
      expectedCaller = trustedRequestCallerPrincipal trusted
      actualCaller = requestClaimsCallerPrincipal claims
      expectedGeneration = trustedRequestGeneration trusted
      actualGeneration = requestClaimsSigningKeyGeneration claims
  if actualCaller == expectedCaller
    then pure ()
    else Left (RequestCallerPrincipalMismatch expectedCaller actualCaller)
  if actualGeneration == expectedGeneration
    then pure ()
    else
      Left
        ( RequestSigningKeyGenerationMismatch
            expectedGeneration
            actualGeneration
        )
  signature <- parseRequestSignature (signedRequestSignature request)
  if Ed25519.verify
    (trustedRequestPublicKey trusted)
    (canonicalRequestClaims claims)
    signature
    then pure ()
    else Left RequestAuthenticationFailed
  expectEqual
    RequestCalleeRoleMismatch
    (verificationExpectedCalleeRole context)
    (requestClaimsCalleeRole claims)
  expectEqual
    RequestRouteMismatch
    (verificationExpectedRoute context)
    (requestClaimsRoute claims)
  expectEqual
    RequestAuthorityScopeMismatch
    (verificationExpectedAuthorityScope context)
    (requestClaimsAuthorityScope claims)
  expectEqual
    RequestAuthorityEpochMismatch
    (verificationExpectedAuthorityEpoch context)
    (requestClaimsAuthorityEpoch claims)
  expectEqual
    RequestDeadlineMismatch
    (verificationExpectedDeadline context)
    (requestClaimsDeadline claims)
  expectEqual
    RequestNonceMismatch
    (verificationExpectedNonce context)
    (requestClaimsNonce claims)
  let deadline = requestClaimsDeadline claims
      now = verificationAuthorityNow context
      maximumDeadline = addAuthorityDuration now (verificationMaximumLifetime context)
  if deadline > now
    then pure ()
    else Left (RequestDeadlineExpired deadline now)
  if deadline <= maximumDeadline
    then pure ()
    else Left (RequestDeadlineExceedsMaximumLifetime deadline maximumDeadline)
  if SHA256.hash (signedRequestBody request) == requestClaimsBodyDigest claims
    then Right (VerifiedControlPlaneRequest request)
    else Left RequestBodyDigestMismatch

expectEqual :: (Eq value) => (value -> value -> err) -> value -> value -> Either err ()
expectEqual mismatch expected actual
  | expected == actual = Right ()
  | otherwise = Left (mismatch expected actual)

parseRequestSignature
  :: RequestSignature -> Either RequestAuthenticationError Ed25519.Signature
parseRequestSignature (RequestSignature bytes) = case Ed25519.signature bytes of
  CryptoFailed _ -> Left RequestSignatureInvalid
  CryptoPassed signature -> Right signature

verifiedRequestRoute :: VerifiedControlPlaneRequest -> ControlPlaneRoute
verifiedRequestRoute (VerifiedControlPlaneRequest request) =
  requestClaimsRoute (signedRequestClaims request)

verifiedRequestCallerPrincipal :: VerifiedControlPlaneRequest -> CallerPrincipal
verifiedRequestCallerPrincipal (VerifiedControlPlaneRequest request) =
  requestClaimsCallerPrincipal (signedRequestClaims request)

verifiedRequestCalleeRole :: VerifiedControlPlaneRequest -> RuntimeRole
verifiedRequestCalleeRole (VerifiedControlPlaneRequest request) =
  requestClaimsCalleeRole (signedRequestClaims request)

verifiedRequestAuthorityScope :: VerifiedControlPlaneRequest -> AuthorityScope
verifiedRequestAuthorityScope (VerifiedControlPlaneRequest request) =
  requestClaimsAuthorityScope (signedRequestClaims request)

verifiedRequestAuthorityEpoch :: VerifiedControlPlaneRequest -> AuthorityEpoch
verifiedRequestAuthorityEpoch (VerifiedControlPlaneRequest request) =
  requestClaimsAuthorityEpoch (signedRequestClaims request)

verifiedRequestDeadline :: VerifiedControlPlaneRequest -> AuthorityTime
verifiedRequestDeadline (VerifiedControlPlaneRequest request) =
  requestClaimsDeadline (signedRequestClaims request)

verifiedRequestNonce :: VerifiedControlPlaneRequest -> RequestNonce
verifiedRequestNonce (VerifiedControlPlaneRequest request) =
  requestClaimsNonce (signedRequestClaims request)

verifiedRequestSigningKeyGeneration
  :: VerifiedControlPlaneRequest -> SigningKeyGeneration
verifiedRequestSigningKeyGeneration (VerifiedControlPlaneRequest request) =
  requestClaimsSigningKeyGeneration (signedRequestClaims request)

-- | SHA-256 of the complete canonical signed envelope.  Retained replay state
-- uses this fixed-width identity to distinguish an exact duplicate from a nonce
-- collision carrying different authenticated claims or body bytes.
verifiedRequestDigestBytes :: VerifiedControlPlaneRequest -> ByteString
verifiedRequestDigestBytes (VerifiedControlPlaneRequest request) =
  SHA256.hash
    (LazyByteString.toStrict (encodeSignedControlPlaneRequest request))

verifiedRequestBody :: VerifiedControlPlaneRequest -> ByteString
verifiedRequestBody (VerifiedControlPlaneRequest request) = signedRequestBody request

-- | The only caller identity a downstream operation decoder may accept for an
-- authenticated request.  It is derived from the verified principal and pinned key
-- generation rather than from caller-chosen payload text.
data VerifiedCallerSlot = VerifiedCallerSlot
  { verifiedCallerSlotPrincipal :: !CallerPrincipal
  , verifiedCallerSlotKeyGeneration :: !SigningKeyGeneration
  }
  deriving stock (Eq, Ord, Show)

verifiedRequestCallerSlot :: VerifiedControlPlaneRequest -> VerifiedCallerSlot
verifiedRequestCallerSlot verified =
  VerifiedCallerSlot
    { verifiedCallerSlotPrincipal = verifiedRequestCallerPrincipal verified
    , verifiedCallerSlotKeyGeneration =
        verifiedRequestSigningKeyGeneration verified
    }

runtimeRoleCode :: RuntimeRole -> Word
runtimeRoleCode role = case role of
  BootstrapBroker -> 1
  GatewayRuntime -> 2
  LifecycleAuthorityRuntime -> 3
  ProviderWorkerRuntime -> 4
  AuthorityBackupRuntime -> 5
  TlsRetentionRuntime -> 6
  TargetSecretAgentRuntime -> 7

runtimeRoleFromCode :: Word -> Maybe RuntimeRole
runtimeRoleFromCode code = case code of
  1 -> Just BootstrapBroker
  2 -> Just GatewayRuntime
  3 -> Just LifecycleAuthorityRuntime
  4 -> Just ProviderWorkerRuntime
  5 -> Just AuthorityBackupRuntime
  6 -> Just TlsRetentionRuntime
  7 -> Just TargetSecretAgentRuntime
  _ -> Nothing

routeCode :: ControlPlaneRoute -> Word
routeCode route = case route of
  LifecycleAuthorityControl -> 14
  LifecycleRetainedSesLease -> 15
  LifecycleAuthorityDecommissionExport -> 16
  TargetSecretDecommissionTombstone -> 17
  LifecyclePulumiCheckpoint -> 18
  LifecycleAuthorityDecommissionStop -> 19
  TargetSecretDecommissionInventory -> 20
  TargetSecretDecommissionCustodyTombstone -> 21
  LifecycleConfigObserve -> 22
  LifecycleConfigProposeCas -> 23
  LifecycleExternalMaterialIngress -> 24
  LifecycleAdminAction -> 25
  LifecycleProviderDispatch -> 26
  TargetTlsPrepareExchange -> 27
  TargetTlsRetain -> 28
  TargetTlsHomeWrap -> 29
  TargetTlsHomeRewrap -> 30
  TargetTlsRestore -> 31
  TargetTlsVerifySource -> 32
  LifecycleTlsRetentionObserve -> 33
  LifecycleTlsRetentionPromote -> 34
  LifecycleAdminActionExecution -> 35
  TargetSecretAdminActionGenerationTombstone -> 36
  TargetSecretAdminActionCustodyTombstone -> 37
  TargetChildCustodyCommit -> 38
  TargetChildRecoveryPrepare -> 39
  TargetChildRecoveryObserve -> 40
  LifecycleBootstrapHandoffAccept -> 41
  LifecycleBootstrapHandoffObserve -> 42
  LifecycleTargetIntentIssue -> 43
  TargetSecretTrustInstall -> 44
  LifecycleRetainedMaterialDelivery -> 45
  TargetRetainedMaterialRewrap -> 46
  LifecycleCleanupRun -> 50
  LifecycleFederationRegister -> 47
  LifecycleAwsAdminProvisioner -> 48
  LifecycleAuthorityBackupExport -> 49
  LifecycleMigrationApply -> 1
  LifecycleProjectionImport -> 2
  LifecycleAuthorityObserve -> 3
  LifecycleOperationSubmit -> 4
  LifecycleOperationObserve -> 5
  ProviderWorkApply -> 6
  ProviderWorkObserve -> 7
  AuthorityBackupCopy -> 8
  AuthorityBackupObserve -> 9
  TlsRetentionStore -> 10
  TlsRetentionRestore -> 11
  TargetMaterialObserve -> 12

routeFromCode :: Word -> Maybe ControlPlaneRoute
routeFromCode code = case code of
  1 -> Just LifecycleMigrationApply
  2 -> Just LifecycleProjectionImport
  3 -> Just LifecycleAuthorityObserve
  4 -> Just LifecycleOperationSubmit
  5 -> Just LifecycleOperationObserve
  6 -> Just ProviderWorkApply
  7 -> Just ProviderWorkObserve
  8 -> Just AuthorityBackupCopy
  9 -> Just AuthorityBackupObserve
  10 -> Just TlsRetentionStore
  11 -> Just TlsRetentionRestore
  12 -> Just TargetMaterialObserve
  13 -> Nothing
  14 -> Just LifecycleAuthorityControl
  15 -> Just LifecycleRetainedSesLease
  16 -> Just LifecycleAuthorityDecommissionExport
  17 -> Just TargetSecretDecommissionTombstone
  18 -> Just LifecyclePulumiCheckpoint
  19 -> Just LifecycleAuthorityDecommissionStop
  20 -> Just TargetSecretDecommissionInventory
  21 -> Just TargetSecretDecommissionCustodyTombstone
  22 -> Just LifecycleConfigObserve
  23 -> Just LifecycleConfigProposeCas
  24 -> Just LifecycleExternalMaterialIngress
  25 -> Just LifecycleAdminAction
  26 -> Just LifecycleProviderDispatch
  27 -> Just TargetTlsPrepareExchange
  28 -> Just TargetTlsRetain
  29 -> Just TargetTlsHomeWrap
  30 -> Just TargetTlsHomeRewrap
  31 -> Just TargetTlsRestore
  32 -> Just TargetTlsVerifySource
  33 -> Just LifecycleTlsRetentionObserve
  34 -> Just LifecycleTlsRetentionPromote
  35 -> Just LifecycleAdminActionExecution
  36 -> Just TargetSecretAdminActionGenerationTombstone
  37 -> Just TargetSecretAdminActionCustodyTombstone
  38 -> Just TargetChildCustodyCommit
  39 -> Just TargetChildRecoveryPrepare
  40 -> Just TargetChildRecoveryObserve
  41 -> Just LifecycleBootstrapHandoffAccept
  42 -> Just LifecycleBootstrapHandoffObserve
  43 -> Just LifecycleTargetIntentIssue
  44 -> Just TargetSecretTrustInstall
  45 -> Just LifecycleRetainedMaterialDelivery
  46 -> Just TargetRetainedMaterialRewrap
  47 -> Just LifecycleFederationRegister
  48 -> Just LifecycleAwsAdminProvisioner
  49 -> Just LifecycleAuthorityBackupExport
  50 -> Just LifecycleCleanupRun
  _ -> Nothing
