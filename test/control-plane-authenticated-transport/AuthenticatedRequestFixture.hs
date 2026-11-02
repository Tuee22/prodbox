{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AuthenticatedRequestFixture
  ( WireContext (..)
  , wireContext
  , captureWire
  , captureWireDetailed
  , verifyCapturedWire
  , frameDigest
  , must
  ) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text qualified as Text
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.CallerPrincipal
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role

must :: (Show err) => Either err value -> value
must = either (error . show) id

data WireContext = WireContext
  { wireSigner :: !RequestSigner
  , wireScope :: !AuthorityScope
  , wireEpoch :: !AuthorityEpoch
  , wireDeadline :: !AuthorityTime
  , wireNonce :: !RequestNonce
  }

wireContext :: CallerPrincipal -> Natural -> Natural -> Int -> WireContext
wireContext principal generation epoch nonceBytes =
  WireContext
    (must (mkRequestSigner principal (must (mkSigningKeyGeneration generation)) (Bytes.replicate 32 17)))
    (must (mkAuthorityScope "wire-preflight"))
    ( case authorityEpochFromValue epoch of
        Just value -> value
        Nothing -> error "invalid positive fixture epoch"
    )
    (authorityTimeFromMicros 2000)
    (must (mkRequestNonce (Bytes.replicate nonceBytes 31)))

-- Only the supplied fixture callback signs. No Vault, cluster, config loader,
-- external HTTP or production credential source is reachable from this fixture.
captureWire
  :: AuthenticatedTransportBounds
  -> WireContext
  -> Bool
  -> ByteString
  -> IO (Either AuthenticatedClientError ControlPlaneResponse, [String], [ByteString])
captureWire bounds context invalidSignature body = do
  (result, events, frames, _) <- captureWireDetailed bounds context invalidSignature body
  pure (result, events, frames)

captureWireDetailed
  :: AuthenticatedTransportBounds
  -> WireContext
  -> Bool
  -> ByteString
  -> IO (Either AuthenticatedClientError ControlPlaneResponse, [String], [ByteString], [ByteString])
captureWireDetailed bounds context invalidSignature body = do
  events <- newIORef []
  frames <- newIORef []
  signedClaims <- newIORef []
  let note label = modifyIORef' events (++ [label])
      signer = wireSigner context
      local :: RequestSigningCapability IO
      local = localRequestSigningCapability signer
      capability =
        must
          ( mkRequestSigningCapability
              (requestSigningCapabilityPrincipal local)
              (requestSigningCapabilityGeneration local)
              (requestSignerPublicKeyBytes signer)
              ( \claims -> do
                  note "signature"
                  modifyIORef' signedClaims (++ [claims])
                  if invalidSignature
                    then pure (Right (Bytes.replicate 64 0))
                    else first (Text.pack . show) <$> signCanonicalBytesWithRequestCapability local claims
              )
          )
      provider label value = note label >> pure (Right value)
      providers =
        AuthenticatedClientProviders
          (provider "signer" capability)
          (provider "scope" (wireScope context))
          (provider "epoch" (wireEpoch context))
          (provider "deadline" (wireDeadline context))
          (provider "nonce" (wireNonce context))
      endpoint = must (mkLifecycleAuthorityEndpoint "http://wire.test.invalid")
      client =
        must
          ( controlPlaneClientWithTransport
              65536
              endpoint
              (\_ _ _ encoded -> modifyIORef' frames (++ [encoded]) >> pure (Right (200, Bytes.empty)))
          )
  result <- callAuthenticatedControlPlane bounds providers client LifecycleProviderDispatchRoute body
  (,,,) result <$> readIORef events <*> readIORef frames <*> readIORef signedClaims

verifyCapturedWire
  :: AuthenticatedTransportBounds
  -> WireContext
  -> ByteString
  -> IO (Either AuthenticatedServerError ByteString)
verifyCapturedWire bounds context encoded = do
  let role = LifecycleAuthorityRuntime
      registry =
        must
          ( mkRouteTrustRegistry
              role
              1
              [(route, trustedRequestKeyFromSigner (wireSigner context)) | route <- routesForRole role]
          )
      providers =
        AuthenticatedServerProviders
          (pure (Right (wireScope context)))
          (pure (Right (wireEpoch context)))
          (pure (Right (authorityTimeFromMicros 1000)))
          (pure (Right registry))
  fmap authenticatedServerInnerBody
    <$> authenticateControlPlaneFrame
      bounds
      (must (authorityDurationFromMicros 10000))
      providers
      role
      LifecycleProviderDispatch
      (Lazy.fromStrict encoded)

frameDigest :: ByteString -> String
frameDigest = concatMap hexadecimal . Bytes.unpack . SHA256.hash
 where
  hexadecimal value = let digits = showHex value "" in replicate (2 - length digits) '0' <> digits
