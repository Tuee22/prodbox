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

    -- * Client wrapper
  , AuthenticatedClientProviders (..)
  , AuthenticatedClientError (..)
  , AuthenticatedClientTransport
  , mkAuthenticatedClientTransport
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane

    -- * Closed route trust registry
  , RouteTrustRegistry
  , RouteTrustRegistryError (..)
  , mkRouteTrustRegistry
  , routeTrustRegistryKeysFor

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
  , decodeAndVerifyControlPlaneRequest
  , encodeSignedControlPlaneRequest
  , mkRequestNonce
  , mkRequestVerificationContext
  , requestNonceBytes
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
  ( ControlPlaneRoute
  , controlPlaneRouteRole
  , routesForRole
  )
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Runtime.Role (RuntimeRole)

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
  let metadata =
        LazyByteString.toStrict
          ( serialise
              AuthenticatedMetadataWire
                { authenticatedMetadataVersion = authenticatedMetadataVersionValue
                , authenticatedMetadataDeadlineMicros = authorityTimeMicros deadline
                , authenticatedMetadataNonce = requestNonceBytes nonce
                }
          )
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

callAuthenticatedClientTransport
  :: AuthenticatedClientTransport r
  -> ControlPlaneRouteFor r
  -> ByteString
  -> IO (Either AuthenticatedClientError ControlPlaneResponse)
callAuthenticatedClientTransport
  (AuthenticatedClientTransport bounds providers client) =
    callAuthenticatedControlPlane bounds providers client

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
callAuthenticatedControlPlane bounds providers client indexedRoute body = do
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
  send signer scope epoch deadline nonce = do
    let route = controlPlaneRouteForValue indexedRoute
        callee = controlPlaneRouteRole route
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
          pure (either (Left . AuthenticatedClientTransportFailed) Right result)

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
  case mkRequestVerificationContext
    trusted
    route
    localRole
    scope
    epoch
    (decodedAuthenticatedDeadline decoded)
    (decodedAuthenticatedNonce decoded)
    now
    maximumLifetime of
    Left _ ->
      -- The server checks route/local-role ownership before reaching this helper,
      -- so this constructor is unreachable without a broken route registry.
      Left RequestAuthenticationFailed
    Right context ->
      decodeAndVerifyControlPlaneRequest
        (maximumSignedEnvelopeBytes bounds)
        context
        (decodedAuthenticatedSignedEnvelope decoded)

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
