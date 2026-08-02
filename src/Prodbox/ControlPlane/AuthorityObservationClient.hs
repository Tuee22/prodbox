{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Typed client projection for the Lifecycle Authority's read-only identity,
-- writer-epoch, and clock observation.  Success requires a canonical response
-- from the role-indexed endpoint whose service identity and authority scope
-- exactly match the caller's expectation, and whose migration writer is the
-- activated replacement.
module Prodbox.ControlPlane.AuthorityObservationClient
  ( ActiveLifecycleAuthorityObservation
  , activeLifecycleAuthorityEpoch
  , activeLifecycleAuthorityTime
  , AuthorityObservationClientError (..)
  , authorityObservationMaximumResponseBytes
  , observeActiveLifecycleAuthority
  , observeActiveLifecycleAuthorityAuthenticated
  , observeLifecycleAuthorityAuthenticated
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityObservationEndpoint
  ( LifecycleAuthorityObservation (..)
  , lifecycleAuthorityServiceIdentity
  , mkLifecycleAuthorityObserveRequest
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneClientError
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAuthorityObserveRoute)
  , callControlPlane
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochFromValue
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , migrationEpochValue
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data ActiveLifecycleAuthorityObservation = ActiveLifecycleAuthorityObservation
  { activeLifecycleAuthorityEpoch :: !AuthorityEpoch
  , activeLifecycleAuthorityTime :: !AuthorityTime
  }
  deriving stock (Eq, Show)

data AuthorityObservationClientError
  = AuthorityObservationRequestInvalid !Text
  | AuthorityObservationTransportFailed !ControlPlaneClientError
  | AuthorityObservationAuthenticatedTransportFailed !AuthenticatedClientError
  | AuthorityObservationHttpStatus !Int !ByteString
  | AuthorityObservationDecodeFailed !ControlPlaneResponseCodecError
  | AuthorityObservationServiceIdentityMismatch !Text !Text
  | AuthorityObservationScopeMismatch !Text !Text
  | AuthorityObservationLegacyWriterActive
  | AuthorityObservationWritersQuiesced
  | AuthorityObservationEpochInvalid !Natural
  deriving stock (Eq, Show)

authorityObservationMaximumResponseBytes :: Int
authorityObservationMaximumResponseBytes = 4096

observeActiveLifecycleAuthority
  :: ControlPlaneClient 'LifecycleAuthorityRuntime
  -> Text
  -> IO
       ( Either
           AuthorityObservationClientError
           ActiveLifecycleAuthorityObservation
       )
observeActiveLifecycleAuthority client expectedScope =
  case mkLifecycleAuthorityObserveRequest expectedScope of
    Left detail -> pure (Left (AuthorityObservationRequestInvalid detail))
    Right request -> do
      response <-
        callControlPlane
          client
          LifecycleAuthorityObserveRoute
          (LazyByteString.toStrict (encodeControlPlaneRequest request))
      pure $ do
        ControlPlaneResponse status responseBody <-
          mapLeft AuthorityObservationTransportFailed response
        if status /= 200
          then Left (AuthorityObservationHttpStatus status responseBody)
          else do
            observation <-
              mapLeft
                AuthorityObservationDecodeFailed
                ( decodeControlPlaneResponse
                    authorityObservationMaximumResponseBytes
                    (LazyByteString.fromStrict responseBody)
                )
            validateObservation expectedScope observation

-- | Authenticated observation for lifecycle callers which already have an
-- epoch-bound client context.  Bootstrapping that context is provisioning
-- ownership; this function never falls back to the raw endpoint.
observeActiveLifecycleAuthorityAuthenticated
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Text
  -> IO
       ( Either
           AuthorityObservationClientError
           ActiveLifecycleAuthorityObservation
       )
observeActiveLifecycleAuthorityAuthenticated transport expectedScope =
  fmap
    (>>= validateObservation expectedScope)
    (observeLifecycleAuthorityAuthenticated transport expectedScope)

-- | Read the exact retained admission projection without manufacturing an
-- active epoch.  Clean-install and repair choreography use this while normal
-- admission is deliberately frozen; steady-state callers should prefer
-- 'observeActiveLifecycleAuthorityAuthenticated'.
observeLifecycleAuthorityAuthenticated
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Text
  -> IO
       ( Either
           AuthorityObservationClientError
           LifecycleAuthorityObservation
       )
observeLifecycleAuthorityAuthenticated transport expectedScope =
  case mkLifecycleAuthorityObserveRequest expectedScope of
    Left detail -> pure (Left (AuthorityObservationRequestInvalid detail))
    Right request -> do
      response <-
        callAuthenticatedClientTransport
          transport
          LifecycleAuthorityObserveRoute
          (LazyByteString.toStrict (encodeControlPlaneRequest request))
      pure $ do
        ControlPlaneResponse status responseBody <-
          mapLeft AuthorityObservationAuthenticatedTransportFailed response
        if status /= 200
          then Left (AuthorityObservationHttpStatus status responseBody)
          else do
            observation <-
              mapLeft
                AuthorityObservationDecodeFailed
                ( decodeControlPlaneResponse
                    authorityObservationMaximumResponseBytes
                    (LazyByteString.fromStrict responseBody)
                )
            validateObservationEnvelope expectedScope observation

validateObservation
  :: Text
  -> LifecycleAuthorityObservation
  -> Either AuthorityObservationClientError ActiveLifecycleAuthorityObservation
validateObservation expectedScope observation =
  do
    validated <- validateObservationEnvelope expectedScope observation
    case observedAuthorityWriterStatus validated of
      MigrationLegacyWriterActive -> Left AuthorityObservationLegacyWriterActive
      MigrationWritersQuiesced -> Left AuthorityObservationWritersQuiesced
      MigrationReplacementWriterActive migrationEpoch -> do
        let epochValue = fromIntegral (migrationEpochValue migrationEpoch)
        epoch <-
          maybe
            (Left (AuthorityObservationEpochInvalid epochValue))
            Right
            (authorityEpochFromValue epochValue)
        Right
          ActiveLifecycleAuthorityObservation
            { activeLifecycleAuthorityEpoch = epoch
            , activeLifecycleAuthorityTime =
                authorityTimeFromMicros (observedAuthorityTimeMicros validated)
            }

validateObservationEnvelope
  :: Text
  -> LifecycleAuthorityObservation
  -> Either AuthorityObservationClientError LifecycleAuthorityObservation
validateObservationEnvelope expectedScope observation
  | observedAuthorityServiceIdentity observation /= lifecycleAuthorityServiceIdentity =
      Left
        ( AuthorityObservationServiceIdentityMismatch
            lifecycleAuthorityServiceIdentity
            (observedAuthorityServiceIdentity observation)
        )
  | observedAuthorityScope observation /= expectedScope =
      Left
        ( AuthorityObservationScopeMismatch
            expectedScope
            (observedAuthorityScope observation)
        )
  | otherwise = Right observation

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert result = case result of
  Left err -> Left (convert err)
  Right value -> Right value
