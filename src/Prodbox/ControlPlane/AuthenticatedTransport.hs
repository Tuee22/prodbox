{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}

-- | Additive authenticated client/server transport wrappers.  The existing raw
-- client and role interpreters remain unchanged; callers opt into this wrapper,
-- which carries an independently canonical nonce/deadline frame beside the
-- signed envelope and exposes inner bytes only after verification.
module Prodbox.ControlPlane.AuthenticatedTransport
  ( -- * Independent bounded framing
    AuthenticatedTransportBounds
  , AuthenticatedTransportBoundsError (..)
  , mkAuthenticatedTransportBounds
  , AuthenticatedFrameError (..)
  , AuthenticatedRequestFootprint
  , authenticatedRequestFootprint
  , authenticatedSigningClaimsBytes
  , authenticatedMetadataBytes
  , authenticatedEnvelopeBytes
  , authenticatedRequestFrameBytes

    -- * Client wrapper
  , AuthenticatedClientProviders (..)
  , AuthenticatedClientError (..)
  , AuthenticatedClientTransport
  , mkAuthenticatedClientTransport
  , authenticatedClientTransportWithin
  , authenticatedClientTransportAtEpoch
  , resolveAuthenticatedClientTransportDeadline
  , callAuthenticatedClientTransport
  , callAuthenticatedTargetTransportWithSignedRequest
  , callAuthenticatedAuthorityObservationWithSignedRequest
  , callAuthenticatedPeerObservationWithSignedRequest
  , callAuthenticatedRpcBirthRegistryWithSignedRequest
  , callAuthenticatedPeerObservation
  , callAuthenticatedControlPlane

    -- * Closed route trust registry
  , RouteTrustRegistry
  , RouteTrustRegistryError (..)
  , mkRouteTrustRegistry
  , routeTrustRegistryKeysFor
  , routeTrustRegistryMaximumKeys

    -- * Server wrapper
  , AuthenticatedServerProviders (..)
  , AuthenticatedServerError (..)
  , AuthenticatedServerRequest
  , authenticateControlPlaneFrame
  , authenticatedServerVerifiedRequest
  , authenticatedServerAuthorityTime
  , authenticatedServerCallerSlot
  , authenticatedServerInnerBody
  , AuthenticatedServeResult (..)
  , serveAuthenticatedControlPlaneFrame
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (rights)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal)
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneClientError
  , ControlPlaneResponse
  , ControlPlaneRouteFor
    ( LifecycleAuthorityControlRoute
    , LifecycleAuthorityPeerObserveRoute
    , LifecycleMigrationApplyRoute
    , TargetSecretTrustInstallRoute
    )
  , callControlPlane
  , controlPlaneRouteForValue
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestAuthenticationError (RequestAuthenticationFailed)
  , RequestBindingError
  , RequestNonce
  , RequestNonceError
  , RequestSigningCapability
  , RequestSigningCapabilityError
  , SignedControlPlaneRequest
  , TrustedRequestKey
  , VerifiedCallerSlot
  , VerifiedControlPlaneRequest
  , cborByteStringEncodedBytes
  , decodeAndVerifyControlPlaneRequest
  , encodeSignedControlPlaneRequest
  , mkPeerObservationVerificationContext
  , mkRequestNonce
  , mkRequestVerificationContext
  , requestNonceBytes
  , requestSigningClaimsEncodedBytes
  , requestSigningEnvelopeEncodedBytes
  , requestSigningFootprint
  , signControlPlaneRequestWith
  , signingKeyGenerationValue
  , trustedRequestCallerPrincipal
  , trustedRequestGeneration
  , verifiedRequestBody
  , verifiedRequestCallerSlot
  )
import Prodbox.ControlPlane.RequestReplay
  ( ReplayAttemptId
  , ReplayCasAttempts
  , ReplayProtectedResult
  , ReplayResponse
  , RequestReplayRepository
  , runReplayProtectedRequest
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAuthorityPeerObserve)
  , controlPlaneRouteRole
  , routesForRole
  )
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch, authorityEpochGenesis)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime))

data AuthenticatedTransportBounds = AuthenticatedTransportBounds
  { maximumAuthenticatedFrameBytes :: !Int
  , maximumAuthenticatedMetadataBytes :: !Int
  , maximumSignedEnvelopeBytes :: !Int
  }
  deriving stock (Eq, Show)

data AuthenticatedTransportBoundsError
  = AuthenticatedFrameMaximumMustBePositive
  | AuthenticatedMetadataMaximumMustBePositive
  | AuthenticatedEnvelopeMaximumMustBePositive
  | AuthenticatedFrameMaximumExceedsHardMaximum !Int !Int
  deriving stock (Eq, Show)

mkAuthenticatedTransportBounds
  :: Int
  -> Int
  -> Int
  -> Either AuthenticatedTransportBoundsError AuthenticatedTransportBounds
mkAuthenticatedTransportBounds frameMaximum metadataMaximum envelopeMaximum
  | frameMaximum <= 0 = Left AuthenticatedFrameMaximumMustBePositive
  | metadataMaximum <= 0 = Left AuthenticatedMetadataMaximumMustBePositive
  | envelopeMaximum <= 0 = Left AuthenticatedEnvelopeMaximumMustBePositive
  | frameMaximum > hardFrameMaximum =
      Left
        ( AuthenticatedFrameMaximumExceedsHardMaximum
            frameMaximum
            hardFrameMaximum
        )
  | otherwise =
      Right
        AuthenticatedTransportBounds
          { maximumAuthenticatedFrameBytes = frameMaximum
          , maximumAuthenticatedMetadataBytes = metadataMaximum
          , maximumSignedEnvelopeBytes = envelopeMaximum
          }
 where
  hardFrameMaximum = 100 * 1024 * 1024

data AuthenticatedFrameError
  = AuthenticatedFrameTooLarge !Int !Int
  | AuthenticatedFrameInvalid
  | AuthenticatedFrameUnsupportedVersion !Word16
  | AuthenticatedFrameNonCanonical
  | AuthenticatedMetadataTooLarge !Int !Int
  | AuthenticatedMetadataInvalid
  | AuthenticatedMetadataUnsupportedVersion !Word16
  | AuthenticatedMetadataNonCanonical
  | AuthenticatedMetadataNonceInvalid !RequestNonceError
  | AuthenticatedSignedEnvelopeTooLarge !Int !Int
  | AuthenticatedRequestBodyTooLarge !Int !Int
  | AuthenticatedPredictedEnvelopeTooLarge !Natural !Int
  | AuthenticatedPredictedFrameTooLarge !Natural !Int
  deriving stock (Eq, Show)

data AuthenticatedMetadataWire = AuthenticatedMetadataWire
  { authenticatedMetadataVersion :: !Word16
  , authenticatedMetadataDeadlineMicros :: !Natural
  , authenticatedMetadataNonce :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthenticatedFrameWire = AuthenticatedFrameWire
  { authenticatedFrameVersion :: !Word16
  , authenticatedFrameMetadata :: !ByteString
  , authenticatedFrameSignedEnvelope :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data DecodedAuthenticatedFrame = DecodedAuthenticatedFrame
  { decodedAuthenticatedDeadline :: !AuthorityTime
  , decodedAuthenticatedNonce :: !RequestNonce
  , decodedAuthenticatedSignedEnvelope :: !LazyByteString.ByteString
  }

authenticatedFrameVersionValue :: Word16
authenticatedFrameVersionValue = 1

authenticatedMetadataVersionValue :: Word16
authenticatedMetadataVersionValue = 1

encodeAuthenticatedFrame
  :: AuthenticatedTransportBounds
  -> AuthorityTime
  -> RequestNonce
  -> SignedControlPlaneRequest
  -> Either AuthenticatedFrameError LazyByteString.ByteString
encodeAuthenticatedFrame bounds deadline nonce signed = do
  let metadata = encodeAuthenticatedMetadata deadline nonce
      envelope = LazyByteString.toStrict (encodeSignedControlPlaneRequest signed)
  checkMaximum AuthenticatedMetadataTooLarge (maximumAuthenticatedMetadataBytes bounds) metadata
  checkMaximum AuthenticatedSignedEnvelopeTooLarge (maximumSignedEnvelopeBytes bounds) envelope
  let framed =
        serialise
          AuthenticatedFrameWire
            { authenticatedFrameVersion = authenticatedFrameVersionValue
            , authenticatedFrameMetadata = metadata
            , authenticatedFrameSignedEnvelope = envelope
            }
      framedLength = fromIntegral (LazyByteString.length framed)
  if framedLength <= maximumAuthenticatedFrameBytes bounds
    then Right framed
    else
      Left
        ( AuthenticatedFrameTooLarge
            framedLength
            (maximumAuthenticatedFrameBytes bounds)
        )

encodeAuthenticatedMetadata :: AuthorityTime -> RequestNonce -> ByteString
encodeAuthenticatedMetadata deadline nonce =
  LazyByteString.toStrict $
    serialise
      AuthenticatedMetadataWire
        { authenticatedMetadataVersion = authenticatedMetadataVersionValue
        , authenticatedMetadataDeadlineMicros = authorityTimeMicros deadline
        , authenticatedMetadataNonce = requestNonceBytes nonce
        }

-- Payload sizes, not HTTP headers, decoded heap, replay or physical admission.
-- This value contains no signed request and invokes no effect provider.
data AuthenticatedRequestFootprint = AuthenticatedRequestFootprint
  { authenticatedSigningClaimsBytes :: !Natural
  , authenticatedMetadataBytes :: !Natural
  , authenticatedEnvelopeBytes :: !Natural
  , authenticatedRequestFrameBytes :: !Natural
  }
  deriving stock (Eq, Show)

authenticatedRequestFootprint
  :: AuthenticatedTransportBounds
  -> RequestSigningCapability m
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> RequestNonce
  -> Word
  -> Either AuthenticatedClientError AuthenticatedRequestFootprint
authenticatedRequestFootprint bounds signer route callee scope epoch deadline nonce bodyBytes = do
  signing <-
    either
      (Left . AuthenticatedClientBindingFailed)
      Right
      (requestSigningFootprint signer route callee scope epoch deadline nonce bodyBytes)
  let metadata = encodeAuthenticatedMetadata deadline nonce
      metadataBytes = ByteString.length metadata
      envelopeBytes = requestSigningEnvelopeEncodedBytes signing
  either (Left . AuthenticatedClientFrameFailed) Right $
    checkMaximum AuthenticatedMetadataTooLarge (maximumAuthenticatedMetadataBytes bounds) metadata
  if envelopeBytes > fromIntegral (maximumSignedEnvelopeBytes bounds)
    then
      Left
        ( AuthenticatedClientFrameFailed
            (AuthenticatedPredictedEnvelopeTooLarge envelopeBytes (maximumSignedEnvelopeBytes bounds))
        )
    else pure ()
  -- The envelope now fits a positive Int bound, so its Word conversion cannot
  -- wrap. The same holds for a materialized strict metadata ByteString length.
  let emptyFrameBytes =
        fromIntegral
          ( LazyByteString.length
              ( serialise
                  (AuthenticatedFrameWire authenticatedFrameVersionValue ByteString.empty ByteString.empty)
              )
          )
      frameBytes =
        emptyFrameBytes
          - 2 * cborByteStringEncodedBytes 0
          + cborByteStringEncodedBytes (fromIntegral metadataBytes)
          + cborByteStringEncodedBytes (fromIntegral envelopeBytes)
  if frameBytes > fromIntegral (maximumAuthenticatedFrameBytes bounds)
    then
      Left
        ( AuthenticatedClientFrameFailed
            (AuthenticatedPredictedFrameTooLarge frameBytes (maximumAuthenticatedFrameBytes bounds))
        )
    else
      Right
        ( AuthenticatedRequestFootprint
            (requestSigningClaimsEncodedBytes signing)
            (fromIntegral metadataBytes)
            envelopeBytes
            frameBytes
        )

decodeAuthenticatedFrame
  :: AuthenticatedTransportBounds
  -> LazyByteString.ByteString
  -> Either AuthenticatedFrameError DecodedAuthenticatedFrame
decodeAuthenticatedFrame bounds bytes = do
  let frameLength = fromIntegral (LazyByteString.length bytes)
  if frameLength <= maximumAuthenticatedFrameBytes bounds
    then pure ()
    else
      Left
        ( AuthenticatedFrameTooLarge
            frameLength
            (maximumAuthenticatedFrameBytes bounds)
        )
  frame <- case deserialiseOrFail bytes of
    Left _ -> Left AuthenticatedFrameInvalid
    Right decoded -> Right decoded
  if authenticatedFrameVersion frame == authenticatedFrameVersionValue
    then pure ()
    else Left (AuthenticatedFrameUnsupportedVersion (authenticatedFrameVersion frame))
  if serialise frame == bytes
    then pure ()
    else Left AuthenticatedFrameNonCanonical
  let metadataBytes = authenticatedFrameMetadata frame
      envelopeBytes = authenticatedFrameSignedEnvelope frame
  checkMaximum
    AuthenticatedMetadataTooLarge
    (maximumAuthenticatedMetadataBytes bounds)
    metadataBytes
  checkMaximum
    AuthenticatedSignedEnvelopeTooLarge
    (maximumSignedEnvelopeBytes bounds)
    envelopeBytes
  metadata <- case deserialiseOrFail (LazyByteString.fromStrict metadataBytes) of
    Left _ -> Left AuthenticatedMetadataInvalid
    Right decoded -> Right decoded
  if authenticatedMetadataVersion metadata == authenticatedMetadataVersionValue
    then pure ()
    else
      Left
        ( AuthenticatedMetadataUnsupportedVersion
            (authenticatedMetadataVersion metadata)
        )
  if LazyByteString.toStrict (serialise metadata) == metadataBytes
    then pure ()
    else Left AuthenticatedMetadataNonCanonical
  nonce <-
    either
      (Left . AuthenticatedMetadataNonceInvalid)
      Right
      (mkRequestNonce (authenticatedMetadataNonce metadata))
  pure
    DecodedAuthenticatedFrame
      { decodedAuthenticatedDeadline =
          authorityTimeFromMicros (authenticatedMetadataDeadlineMicros metadata)
      , decodedAuthenticatedNonce = nonce
      , decodedAuthenticatedSignedEnvelope = LazyByteString.fromStrict envelopeBytes
      }

checkMaximum
  :: (Int -> Int -> errorValue)
  -> Int
  -> ByteString
  -> Either errorValue ()
checkMaximum tooLarge maximumBytes bytes
  | ByteString.length bytes <= maximumBytes = Right ()
  | otherwise = Left (tooLarge (ByteString.length bytes) maximumBytes)

data AuthenticatedClientProviders m = AuthenticatedClientProviders
  { provideAuthenticatedClientSigner
      :: m (Either Text (RequestSigningCapability m))
  , provideAuthenticatedClientScope :: m (Either Text AuthorityScope)
  , provideAuthenticatedClientEpoch :: m (Either Text AuthorityEpoch)
  , provideAuthenticatedClientDeadline :: m (Either Text AuthorityTime)
  , provideAuthenticatedClientNonce :: m (Either Text RequestNonce)
  }

data AuthenticatedClientError
  = AuthenticatedClientSignerUnavailable !Text
  | AuthenticatedClientScopeUnavailable !Text
  | AuthenticatedClientEpochUnavailable !Text
  | AuthenticatedClientDeadlineUnavailable !Text
  | AuthenticatedClientNonceUnavailable !Text
  | AuthenticatedClientBindingFailed !RequestBindingError
  | AuthenticatedClientSigningFailed !RequestSigningCapabilityError
  | AuthenticatedClientFrameFailed !AuthenticatedFrameError
  | AuthenticatedClientTransportFailed !ControlPlaneClientError
  deriving stock (Eq, Show)

-- | Complete authenticated client boundary.  Callers which hold this value
-- cannot accidentally fall back to the raw transport because the indexed
-- client, bounds, and all security-sensitive providers travel together.
data AuthenticatedClientTransport (r :: RuntimeRole)
  = AuthenticatedClientTransport
      !AuthenticatedTransportBounds
      !(AuthenticatedClientProviders IO)
      !(ControlPlaneClient r)

mkAuthenticatedClientTransport
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient r
  -> AuthenticatedClientTransport r
mkAuthenticatedClientTransport = AuthenticatedClientTransport

-- | A nested request may shorten its provider's deadline, never renew it.
-- All other authentication providers and the role-indexed client are retained.
authenticatedClientTransportWithin
  :: AuthorityTime -> AuthenticatedClientTransport r -> AuthenticatedClientTransport r
authenticatedClientTransportWithin deadline (AuthenticatedClientTransport bounds providers client) =
  AuthenticatedClientTransport
    bounds
    ( providers
        { provideAuthenticatedClientDeadline =
            fmap (fmap (min deadline)) (provideAuthenticatedClientDeadline providers)
        }
    )
    client

callAuthenticatedClientTransport
  :: AuthenticatedClientTransport r
  -> ControlPlaneRouteFor r
  -> ByteString
  -> IO (Either AuthenticatedClientError ControlPlaneResponse)
callAuthenticatedClientTransport
  (AuthenticatedClientTransport bounds providers client) =
    callAuthenticatedControlPlane bounds providers client

-- | Retain the exact signed request only for the Target trust route, so an
-- opt-in response verifier can bind the reply to that request. Callers own the
-- request/body lifetime and must enforce a single deadline over the full call.
callAuthenticatedTargetTransportWithSignedRequest
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> ByteString
  -> IO (Either AuthenticatedClientError (SignedControlPlaneRequest, ControlPlaneResponse))
callAuthenticatedTargetTransportWithSignedRequest (AuthenticatedClientTransport bounds providers client) =
  callAuthenticatedControlPlaneWithSignedRequest bounds providers client TargetSecretTrustInstallRoute

-- | Keep only these Authority read requests for response verification. The
-- caller owns their lifetime and the original complete-operation deadline.
callAuthenticatedAuthorityObservationWithSignedRequest
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ByteString
  -> IO (Either AuthenticatedClientError (SignedControlPlaneRequest, ControlPlaneResponse))
callAuthenticatedAuthorityObservationWithSignedRequest (AuthenticatedClientTransport bounds providers client) =
  callAuthenticatedControlPlaneWithSignedRequest
    bounds
    providers
    client
    LifecycleAuthorityControlRoute

callAuthenticatedPeerObservationWithSignedRequest
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ByteString
  -> IO (Either AuthenticatedClientError (SignedControlPlaneRequest, ControlPlaneResponse))
callAuthenticatedPeerObservationWithSignedRequest (AuthenticatedClientTransport bounds providers client) =
  callAuthenticatedControlPlaneWithSignedRequest
    bounds
    (providers {provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)})
    client
    LifecycleAuthorityPeerObserveRoute

callAuthenticatedRpcBirthRegistryWithSignedRequest
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ByteString
  -> IO (Either AuthenticatedClientError (SignedControlPlaneRequest, ControlPlaneResponse))
callAuthenticatedRpcBirthRegistryWithSignedRequest (AuthenticatedClientTransport bounds providers client) =
  callAuthenticatedControlPlaneWithSignedRequest bounds providers client LifecycleMigrationApplyRoute

-- | Resolve once so a caller can physically bound signing, refresh and HTTP
-- by the same deadline that the resulting transport will sign.
-- | A verified peer refresh changes only the epoch. Identity, scope,
-- nonce, deadline and role-indexed endpoint providers remain fixed.
authenticatedClientTransportAtEpoch
  :: AuthorityEpoch -> AuthenticatedClientTransport r -> AuthenticatedClientTransport r
authenticatedClientTransportAtEpoch epoch (AuthenticatedClientTransport bounds providers client) =
  AuthenticatedClientTransport
    bounds
    (providers {provideAuthenticatedClientEpoch = pure (Right epoch)})
    client

resolveAuthenticatedClientTransportDeadline
  :: AuthorityTime
  -> AuthenticatedClientTransport r
  -> IO (Either AuthenticatedClientError (AuthorityTime, AuthenticatedClientTransport r))
resolveAuthenticatedClientTransportDeadline parent (AuthenticatedClientTransport bounds providers client) = do
  observed <- provideAuthenticatedClientDeadline providers
  pure $ case observed of
    Left detail -> Left (AuthenticatedClientDeadlineUnavailable detail)
    Right deadline ->
      let effective = min parent deadline
       in Right
            ( effective
            , AuthenticatedClientTransport
                bounds
                (providers {provideAuthenticatedClientDeadline = pure (Right effective)})
                client
            )

-- | The historical-epoch signer cannot escape through an ordinary transport:
-- its only operation is this fixed authenticated metadata route.
callAuthenticatedPeerObservation
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ByteString
  -> IO (Either AuthenticatedClientError ControlPlaneResponse)
callAuthenticatedPeerObservation (AuthenticatedClientTransport bounds providers client) =
  callAuthenticatedControlPlane
    bounds
    (providers {provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)})
    client
    LifecycleAuthorityPeerObserveRoute

-- | Obtain every security-sensitive value from an injected typed provider,
-- sign the exact inner bytes, frame the independent nonce/deadline projection,
-- and send it through the existing role-indexed client.
callAuthenticatedControlPlane
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient r
  -> ControlPlaneRouteFor r
  -> ByteString
  -> IO (Either AuthenticatedClientError ControlPlaneResponse)
callAuthenticatedControlPlane bounds providers client indexedRoute body
  | ByteString.length body > bodyMaximum =
      pure $
        Left $
          AuthenticatedClientFrameFailed
            (AuthenticatedRequestBodyTooLarge (ByteString.length body) bodyMaximum)
  | otherwise = do
      signerResult <- provideAuthenticatedClientSigner providers
      case signerResult of
        Left detail -> pure (Left (AuthenticatedClientSignerUnavailable detail))
        Right signer -> do
          scopeResult <- provideAuthenticatedClientScope providers
          case scopeResult of
            Left detail -> pure (Left (AuthenticatedClientScopeUnavailable detail))
            Right scope -> do
              epochResult <- provideAuthenticatedClientEpoch providers
              case epochResult of
                Left detail -> pure (Left (AuthenticatedClientEpochUnavailable detail))
                Right epoch -> do
                  deadlineResult <- provideAuthenticatedClientDeadline providers
                  case deadlineResult of
                    Left detail -> pure (Left (AuthenticatedClientDeadlineUnavailable detail))
                    Right deadline -> do
                      nonceResult <- provideAuthenticatedClientNonce providers
                      case nonceResult of
                        Left detail -> pure (Left (AuthenticatedClientNonceUnavailable detail))
                        Right nonce -> send signer scope epoch deadline nonce
 where
  bodyMaximum = min (maximumAuthenticatedFrameBytes bounds) (maximumSignedEnvelopeBytes bounds)
  send signer scope epoch deadline nonce = do
    let route = controlPlaneRouteForValue indexedRoute
        callee = controlPlaneRouteRole route
    case authenticatedRequestFootprint
      bounds
      signer
      route
      callee
      scope
      epoch
      deadline
      nonce
      (fromIntegral (ByteString.length body)) of
      Left cause -> pure (Left cause)
      Right _ -> do
        signedResult <-
          signControlPlaneRequestWith
            signer
            route
            callee
            scope
            epoch
            deadline
            nonce
            body
        case signedResult of
          Left (Left err) -> pure (Left (AuthenticatedClientBindingFailed err))
          Left (Right err) -> pure (Left (AuthenticatedClientSigningFailed err))
          Right signed -> case encodeAuthenticatedFrame bounds deadline nonce signed of
            Left err -> pure (Left (AuthenticatedClientFrameFailed err))
            Right framed -> do
              result <- callControlPlane client indexedRoute (LazyByteString.toStrict framed)
              pure
                (either (Left . AuthenticatedClientTransportFailed) Right result)

-- The opt-in Target variant retains its signed request until verification.
-- Keep the existing transport above independent of that extra lifetime.
callAuthenticatedControlPlaneWithSignedRequest
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient r
  -> ControlPlaneRouteFor r
  -> ByteString
  -> IO (Either AuthenticatedClientError (SignedControlPlaneRequest, ControlPlaneResponse))
callAuthenticatedControlPlaneWithSignedRequest bounds providers client indexedRoute body
  | ByteString.length body > bodyMaximum =
      pure $
        Left $
          AuthenticatedClientFrameFailed
            (AuthenticatedRequestBodyTooLarge (ByteString.length body) bodyMaximum)
  | otherwise = do
      signerResult <- provideAuthenticatedClientSigner providers
      case signerResult of
        Left detail -> pure (Left (AuthenticatedClientSignerUnavailable detail))
        Right signer -> do
          scopeResult <- provideAuthenticatedClientScope providers
          case scopeResult of
            Left detail -> pure (Left (AuthenticatedClientScopeUnavailable detail))
            Right scope -> do
              epochResult <- provideAuthenticatedClientEpoch providers
              case epochResult of
                Left detail -> pure (Left (AuthenticatedClientEpochUnavailable detail))
                Right epoch -> do
                  deadlineResult <- provideAuthenticatedClientDeadline providers
                  case deadlineResult of
                    Left detail -> pure (Left (AuthenticatedClientDeadlineUnavailable detail))
                    Right deadline -> do
                      nonceResult <- provideAuthenticatedClientNonce providers
                      case nonceResult of
                        Left detail -> pure (Left (AuthenticatedClientNonceUnavailable detail))
                        Right nonce -> send signer scope epoch deadline nonce
 where
  bodyMaximum = min (maximumAuthenticatedFrameBytes bounds) (maximumSignedEnvelopeBytes bounds)
  send signer scope epoch deadline nonce = do
    let route = controlPlaneRouteForValue indexedRoute
        callee = controlPlaneRouteRole route
    case authenticatedRequestFootprint
      bounds
      signer
      route
      callee
      scope
      epoch
      deadline
      nonce
      (fromIntegral (ByteString.length body)) of
      Left cause -> pure (Left cause)
      Right _ -> do
        signedResult <-
          signControlPlaneRequestWith
            signer
            route
            callee
            scope
            epoch
            deadline
            nonce
            body
        case signedResult of
          Left (Left err) -> pure (Left (AuthenticatedClientBindingFailed err))
          Left (Right err) -> pure (Left (AuthenticatedClientSigningFailed err))
          Right signed -> case encodeAuthenticatedFrame bounds deadline nonce signed of
            Left err -> pure (Left (AuthenticatedClientFrameFailed err))
            Right framed -> do
              result <- callControlPlane client indexedRoute (LazyByteString.toStrict framed)
              pure
                (either (Left . AuthenticatedClientTransportFailed) (\response -> Right (signed, response)) result)

data RouteTrustRegistry = RouteTrustRegistry
  { routeTrustRole :: !RuntimeRole
  , routeTrustMaximumKeysPerRoute :: !Natural
  , routeTrustKeys :: !(Map ControlPlaneRoute [TrustedRequestKey])
  }

-- | Read the immutable trust entries for one closed route.  Construction has
-- already proved totality and role ownership; callers use this projection to
-- derive other pinned registries (for example the Lifecycle Authority's
-- registered operation clients) from the same trust source of truth.
routeTrustRegistryKeysFor
  :: ControlPlaneRoute -> RouteTrustRegistry -> [TrustedRequestKey]
routeTrustRegistryKeysFor route registry =
  Map.findWithDefault [] route (routeTrustKeys registry)

routeTrustRegistryMaximumKeys :: RouteTrustRegistry -> Natural
routeTrustRegistryMaximumKeys = routeTrustMaximumKeysPerRoute

data RouteTrustRegistryError
  = RouteTrustMaximumMustBePositive
  | RouteTrustMaximumExceedsHardMaximum !Natural !Natural
  | RouteTrustRouteNotOwned !RuntimeRole !ControlPlaneRoute
  | RouteTrustRouteMissing !ControlPlaneRoute
  | RouteTrustRouteOverCapacity !ControlPlaneRoute !Natural !Natural
  | RouteTrustDuplicateIdentity
      !ControlPlaneRoute
      !CallerPrincipal
      !Natural
  deriving stock (Eq, Show)

-- | Build a total registry over the callee role's closed route family.  A newly
-- added owned route is a constructor-time failure until its allowed callers are
-- registered, while a foreign route is rejected outright.
mkRouteTrustRegistry
  :: RuntimeRole
  -> Natural
  -> [(ControlPlaneRoute, TrustedRequestKey)]
  -> Either RouteTrustRegistryError RouteTrustRegistry
mkRouteTrustRegistry role maximumKeys entries
  | maximumKeys == 0 = Left RouteTrustMaximumMustBePositive
  | maximumKeys > hardMaximum =
      Left (RouteTrustMaximumExceedsHardMaximum maximumKeys hardMaximum)
  | otherwise = do
      registry <- foldM insertEntry Map.empty entries
      traverse_ (validateRoute registry) (routesForRole role)
      pure
        RouteTrustRegistry
          { routeTrustRole = role
          , routeTrustMaximumKeysPerRoute = maximumKeys
          , routeTrustKeys = registry
          }
 where
  hardMaximum = 16
  insertEntry registry (route, trusted) =
    if controlPlaneRouteRole route /= role
      then Left (RouteTrustRouteNotOwned role route)
      else
        let existing = Map.findWithDefault [] route registry
            identity = trustedIdentity trusted
         in if identity `elem` fmap trustedIdentity existing
              then
                Left
                  ( RouteTrustDuplicateIdentity
                      route
                      (trustedRequestCallerPrincipal trusted)
                      (snd identity)
                  )
              else
                let next = existing <> [trusted]
                 in if fromIntegral (length next) > maximumKeys
                      then
                        Left
                          ( RouteTrustRouteOverCapacity
                              route
                              (fromIntegral (length next))
                              maximumKeys
                          )
                      else Right (Map.insert route next registry)
  validateRoute registry route =
    case Map.lookup route registry of
      Nothing -> Left (RouteTrustRouteMissing route)
      Just [] -> Left (RouteTrustRouteMissing route)
      Just _ -> Right ()

trustedIdentity :: TrustedRequestKey -> (CallerPrincipal, Natural)
trustedIdentity trusted =
  ( trustedRequestCallerPrincipal trusted
  , signingKeyGenerationValue (trustedRequestGeneration trusted)
  )

data AuthenticatedServerProviders m = AuthenticatedServerProviders
  { provideAuthenticatedServerScope :: m (Either Text AuthorityScope)
  , provideAuthenticatedServerEpoch :: m (Either Text AuthorityEpoch)
  , provideAuthenticatedServerTime :: m (Either Text AuthorityTime)
  , provideAuthenticatedServerTrustRegistry :: m (Either Text RouteTrustRegistry)
  }

data AuthenticatedServerError
  = AuthenticatedServerFrameFailed !AuthenticatedFrameError
  | AuthenticatedServerRouteRoleMismatch !ControlPlaneRoute !RuntimeRole !RuntimeRole
  | AuthenticatedServerScopeUnavailable !Text
  | AuthenticatedServerEpochUnavailable !Text
  | AuthenticatedServerTimeUnavailable !Text
  | AuthenticatedServerTrustRegistryUnavailable !Text
  | AuthenticatedServerTrustRegistryRoleMismatch !RuntimeRole !RuntimeRole
  | AuthenticatedServerRequestAuthenticationFailed ![RequestAuthenticationError]
  | AuthenticatedServerRequestAuthenticationAmbiguous
  | AuthenticatedServerBindingFailed !RequestBindingError
  deriving stock (Eq, Show)

data AuthenticatedServerRequest = AuthenticatedServerRequest
  { authenticatedServerVerifiedRequest :: !VerifiedControlPlaneRequest
  , authenticatedServerAuthorityTime :: !AuthorityTime
  }
  deriving stock (Eq, Show)

authenticatedServerCallerSlot :: AuthenticatedServerRequest -> VerifiedCallerSlot
authenticatedServerCallerSlot =
  verifiedRequestCallerSlot . authenticatedServerVerifiedRequest

authenticatedServerInnerBody :: AuthenticatedServerRequest -> ByteString
authenticatedServerInnerBody =
  verifiedRequestBody . authenticatedServerVerifiedRequest

-- | Verify before exposing inner bytes.  The trusted key is selected only from
-- the bounded route registry; every candidate remains pinned to its own caller
-- role and generation by the lower-level verifier.
authenticateControlPlaneFrame
  :: (Monad m)
  => AuthenticatedTransportBounds
  -> AuthorityDuration
  -> AuthenticatedServerProviders m
  -> RuntimeRole
  -> ControlPlaneRoute
  -> LazyByteString.ByteString
  -> m (Either AuthenticatedServerError AuthenticatedServerRequest)
authenticateControlPlaneFrame bounds maximumLifetime providers localRole route raw =
  case decodeAuthenticatedFrame bounds raw of
    Left err -> pure (Left (AuthenticatedServerFrameFailed err))
    Right decoded
      | controlPlaneRouteRole route /= localRole ->
          pure
            ( Left
                ( AuthenticatedServerRouteRoleMismatch
                    route
                    localRole
                    (controlPlaneRouteRole route)
                )
            )
      | otherwise -> do
          scopeResult <- provideAuthenticatedServerScope providers
          epochResult <- provideAuthenticatedServerEpoch providers
          timeResult <- provideAuthenticatedServerTime providers
          trustResult <- provideAuthenticatedServerTrustRegistry providers
          pure $ do
            scope <- either (Left . AuthenticatedServerScopeUnavailable) Right scopeResult
            epoch <- either (Left . AuthenticatedServerEpochUnavailable) Right epochResult
            now <- either (Left . AuthenticatedServerTimeUnavailable) Right timeResult
            registry <-
              either
                (Left . AuthenticatedServerTrustRegistryUnavailable)
                Right
                trustResult
            if routeTrustRole registry == localRole
              then pure ()
              else
                Left
                  ( AuthenticatedServerTrustRegistryRoleMismatch
                      localRole
                      (routeTrustRole registry)
                  )
            let trustedKeys = Map.findWithDefault [] route (routeTrustKeys registry)
                attempts =
                  fmap
                    ( verifyWithKey
                        bounds
                        decoded
                        route
                        localRole
                        scope
                        epoch
                        now
                        maximumLifetime
                    )
                    trustedKeys
                failures = [err | Left err <- attempts]
                successes = rights attempts
            case successes of
              [verified] ->
                Right
                  AuthenticatedServerRequest
                    { authenticatedServerVerifiedRequest = verified
                    , authenticatedServerAuthorityTime = now
                    }
              [] -> Left (AuthenticatedServerRequestAuthenticationFailed failures)
              _ -> Left AuthenticatedServerRequestAuthenticationAmbiguous

verifyWithKey
  :: AuthenticatedTransportBounds
  -> DecodedAuthenticatedFrame
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> AuthorityDuration
  -> TrustedRequestKey
  -> Either RequestAuthenticationError VerifiedControlPlaneRequest
verifyWithKey bounds decoded route localRole scope epoch now maximumLifetime trusted =
  case contextResult of
    Left _ ->
      -- The server checks route/local-role ownership before reaching this helper,
      -- so this constructor is unreachable without a broken route registry.
      Left RequestAuthenticationFailed
    Right context ->
      decodeAndVerifyControlPlaneRequest
        (maximumSignedEnvelopeBytes bounds)
        context
        (decodedAuthenticatedSignedEnvelope decoded)
 where
  contextResult
    | route == LifecycleAuthorityPeerObserve =
        Right
          ( mkPeerObservationVerificationContext
              trusted
              scope
              epoch
              (decodedAuthenticatedDeadline decoded)
              (decodedAuthenticatedNonce decoded)
              now
              maximumLifetime
          )
    | otherwise =
        mkRequestVerificationContext
          trusted
          route
          localRole
          scope
          epoch
          (decodedAuthenticatedDeadline decoded)
          (decodedAuthenticatedNonce decoded)
          now
          maximumLifetime

data AuthenticatedServeResult failure
  = AuthenticatedServeRefused !AuthenticatedServerError
  | AuthenticatedServeReplayed !(ReplayProtectedResult failure)
  deriving stock (Eq, Show)

-- | Full additive server seam: authenticate, durably reserve/read back, then
-- pass the verified caller slot and inner bytes to the effect handler.  The
-- handler is unreachable on every authentication/replay refusal.
serveAuthenticatedControlPlaneFrame
  :: (Monad m)
  => AuthenticatedTransportBounds
  -> AuthorityDuration
  -> AuthenticatedServerProviders m
  -> RuntimeRole
  -> ControlPlaneRoute
  -> ReplayCasAttempts
  -> RequestReplayRepository m revision
  -> ReplayAttemptId
  -> LazyByteString.ByteString
  -> (AuthenticatedServerRequest -> m (Either failure ReplayResponse))
  -> m (AuthenticatedServeResult failure)
serveAuthenticatedControlPlaneFrame
  bounds
  maximumLifetime
  providers
  localRole
  route
  casAttempts
  repository
  attempt
  raw
  handler = do
    authenticated <-
      authenticateControlPlaneFrame
        bounds
        maximumLifetime
        providers
        localRole
        route
        raw
    case authenticated of
      Left err -> pure (AuthenticatedServeRefused err)
      Right request -> do
        replayed <-
          runReplayProtectedRequest
            casAttempts
            repository
            (authenticatedServerAuthorityTime request)
            attempt
            (authenticatedServerVerifiedRequest request)
            (handler request)
        pure (AuthenticatedServeReplayed replayed)
