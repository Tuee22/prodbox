{-# LANGUAGE OverloadedStrings #-}

module HistoryAuthorityAuthenticationFixture (fakeTransportBounds, fakeMaximumLifetime, fakeClientProviders, fakeServerProviders) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route (routesForRole)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

fakeMaximumResponseBytes :: Int
fakeMaximumResponseBytes = 4 * 1024 * 1024

fakeTransportBounds :: AuthenticatedTransportBounds
fakeTransportBounds =
  mustRight
    ( mkAuthenticatedTransportBounds
        fakeMaximumResponseBytes
        256
        (fakeMaximumResponseBytes - 1024)
    )

fakeMaximumLifetime :: AuthorityDuration
fakeMaximumLifetime = mustRight (authorityDurationFromMicros 5000)

fakeNow, fakeDeadline :: AuthorityTime
fakeNow = authorityTimeFromMicros 1000
fakeDeadline = authorityTimeFromMicros 2000

fakeAuthorityScope :: AuthorityScope
fakeAuthorityScope = mustRight (mkAuthorityScope "cascade-history-import")

fakeRequestSigner :: RequestSigner
fakeRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString8.pack "0123456789abcdef0123456789abcdef")
    )

fakeRequestNonce :: RequestNonce
fakeRequestNonce =
  mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

fakeClientProviders :: AuthenticatedClientProviders IO
fakeClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability fakeRequestSigner))
    , provideAuthenticatedClientScope = pure (Right fakeAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right fakeDeadline)
    , provideAuthenticatedClientNonce = pure (Right fakeRequestNonce)
    }

fakeServerProviders :: AuthenticatedServerProviders IO
fakeServerProviders =
  AuthenticatedServerProviders
    { provideAuthenticatedServerScope = pure (Right fakeAuthorityScope)
    , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedServerTime = pure (Right fakeNow)
    , provideAuthenticatedServerTrustRegistry =
        pure (Right fakeTrustRegistry)
    }

fakeTrustRegistry :: RouteTrustRegistry
fakeTrustRegistry =
  mustRight
    ( mkRouteTrustRegistry
        LifecycleAuthorityRuntime
        1
        [ (route, trustedRequestKeyFromSigner fakeRequestSigner)
        | route <- routesForRole LifecycleAuthorityRuntime
        ]
    )

mustRight :: (Show cause) => Either cause value -> value
mustRight = either (error . show) id
