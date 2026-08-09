{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed authenticated composition for a role handler.  Authentication and
-- durable request replay complete before the handler receives the opaque
-- verified caller slot.  Raw request bodies therefore have no field or
-- constructor with which to inject a principal.
module Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  , contextFreeAuthenticatedRoleHandler
  , AuthenticatedRoleProviders (..)
  , AuthenticatedRoleHandlerFailure (..)
  , authenticatedRoleInterpreter

    -- * Stable total HTTP projections
  , authenticatedServerErrorResponse
  , replayProtectedResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedServerError (..)
  , AuthenticatedServerProviders
  , AuthenticatedTransportBounds
  , authenticateControlPlaneFrame
  , authenticatedServerAuthorityTime
  , authenticatedServerCallerSlot
  , authenticatedServerInnerBody
  , authenticatedServerVerifiedRequest
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  )
import Prodbox.ControlPlane.RequestReplay
  ( ReplayAttemptId
  , ReplayCasAttempts
  , ReplayProtectedResult (..)
  , ReplayResponse
  , ReplayResponseError
  , RequestReplayLimits
  , RequestReplayRepository
  , mkReplayResponse
  , replayResponseBody
  , replayResponseStatus
  , runReplayProtectedRequest
  )
import Prodbox.ControlPlane.RoleReadiness (RoleReadinessSource)
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  )
import Prodbox.ControlPlane.Server
  ( RoleInterpreter (RoleInterpreter, interpreterHandle, interpreterReadiness)
  )
import Prodbox.Lifecycle.Lease (AuthorityDuration)
import Prodbox.Runtime.Role (RuntimeRole)

data AuthenticatedRoleHandler m = AuthenticatedRoleHandler
  { authenticatedHandlerReadiness :: !RoleReadinessSource
  , authenticatedHandlerHandle
      :: VerifiedCallerSlot
      -> ControlPlaneRoute
      -> ByteString
      -> m (Maybe (Int, ByteString))
  }

-- | Lift a handler that has no caller-dependent operations.  This is the only
-- adapter from the context-free server seam; caller-aware endpoints must use
-- 'AuthenticatedRoleHandler' directly.
contextFreeAuthenticatedRoleHandler
  :: RoleInterpreter m -> AuthenticatedRoleHandler m
contextFreeAuthenticatedRoleHandler interpreter =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = interpreterReadiness interpreter
    , authenticatedHandlerHandle = \_ route body ->
        interpreterHandle interpreter route body
    }

data AuthenticatedRoleProviders m = AuthenticatedRoleProviders
  { authenticatedRoleServerProviders :: !(AuthenticatedServerProviders m)
  , provideAuthenticatedReplayAttempt :: m (Either Text ReplayAttemptId)
  }

data AuthenticatedRoleHandlerFailure
  = AuthenticatedRoleHandlerUnavailable
  | AuthenticatedRoleHandlerResponseInvalid !ReplayResponseError
  deriving stock (Eq, Show)

-- | Authenticate and replay-protect a context-aware role handler.  Readiness
-- is preserved.  Every owned-route invocation returns a concrete response:
-- authentication, replay, handler, and
-- completion failures can never fall through to an unclassified exception.
authenticatedRoleInterpreter
  :: (Monad m)
  => AuthenticatedTransportBounds
  -> AuthorityDuration
  -> AuthenticatedRoleProviders m
  -> RuntimeRole
  -> ReplayCasAttempts
  -> RequestReplayLimits
  -> RequestReplayRepository m revision
  -> AuthenticatedRoleHandler m
  -> RoleInterpreter m
authenticatedRoleInterpreter
  transportBounds
  maximumLifetime
  providers
  localRole
  casAttempts
  replayLimits
  replayRepository
  inner =
    RoleInterpreter
      { interpreterReadiness = authenticatedHandlerReadiness inner
      , interpreterHandle = handle
      }
   where
    handle route rawFrame = do
      authenticated <-
        authenticateControlPlaneFrame
          transportBounds
          maximumLifetime
          (authenticatedRoleServerProviders providers)
          localRole
          route
          (LazyByteString.fromStrict rawFrame)
      case authenticated of
        Left err -> pure (Just (authenticatedServerErrorResponse err))
        Right request -> do
          attempted <- provideAuthenticatedReplayAttempt providers
          case attempted of
            Left _ -> pure (Just (503, "authenticated-replay-attempt-unavailable\n"))
            Right attempt -> do
              replayed <-
                runReplayProtectedRequest
                  casAttempts
                  replayRepository
                  (authenticatedServerAuthorityTime request)
                  attempt
                  (authenticatedServerVerifiedRequest request)
                  ( runInner
                      (authenticatedServerCallerSlot request)
                      route
                      (authenticatedServerInnerBody request)
                  )
              pure (Just (replayProtectedResponse replayed))
    runInner callerSlot route body = do
      handled <- authenticatedHandlerHandle inner callerSlot route body
      pure $ case handled of
        Nothing -> Left AuthenticatedRoleHandlerUnavailable
        Just (status, responseBody) ->
          first
            AuthenticatedRoleHandlerResponseInvalid
            (mkReplayResponse replayLimits status responseBody)

authenticatedServerErrorResponse :: AuthenticatedServerError -> (Int, ByteString)
authenticatedServerErrorResponse err = case err of
  AuthenticatedServerFrameFailed _ ->
    (400, "authenticated-frame-refused\n")
  AuthenticatedServerRouteRoleMismatch {} ->
    (500, "authenticated-route-role-mismatch\n")
  AuthenticatedServerScopeUnavailable _ ->
    (503, "authenticated-scope-unavailable\n")
  AuthenticatedServerEpochUnavailable _ ->
    (503, "authenticated-epoch-unavailable\n")
  AuthenticatedServerTimeUnavailable _ ->
    (503, "authenticated-time-unavailable\n")
  AuthenticatedServerTrustRegistryUnavailable _ ->
    (503, "authenticated-trust-unavailable\n")
  AuthenticatedServerTrustRegistryRoleMismatch {} ->
    (500, "authenticated-trust-role-mismatch\n")
  AuthenticatedServerRequestAuthenticationFailed _ ->
    (401, "authentication-refused\n")
  AuthenticatedServerRequestAuthenticationAmbiguous ->
    (401, "authentication-ambiguous\n")
  AuthenticatedServerBindingFailed _ ->
    (500, "authentication-binding-invalid\n")

replayProtectedResponse
  :: ReplayProtectedResult AuthenticatedRoleHandlerFailure
  -> (Int, ByteString)
replayProtectedResponse result = case result of
  ReplayProtectedExecuted response -> replayResponse response
  ReplayProtectedRecovered response -> replayResponse response
  ReplayProtectedInFlight -> (409, "authenticated-replay-in-flight\n")
  ReplayProtectedTombstoned -> (409, "authenticated-replay-tombstoned\n")
  ReplayProtectedDigestConflict -> (409, "authenticated-replay-digest-conflict\n")
  ReplayProtectedExpired -> (408, "authenticated-replay-expired\n")
  ReplayProtectedCapacityExhausted ->
    (503, "authenticated-replay-capacity-exhausted\n")
  ReplayProtectedUnavailable _ ->
    (503, "authenticated-replay-unavailable\n")
  ReplayProtectedAttemptsExhausted ->
    (503, "authenticated-replay-attempts-exhausted\n")
  ReplayProtectedEffectFailed failure -> handlerFailureResponse failure
  ReplayProtectedCompletionUnconfirmed _ ->
    (503, "authenticated-replay-completion-unconfirmed\n")

replayResponse :: ReplayResponse -> (Int, ByteString)
replayResponse response =
  (replayResponseStatus response, replayResponseBody response)

handlerFailureResponse :: AuthenticatedRoleHandlerFailure -> (Int, ByteString)
handlerFailureResponse failure = case failure of
  AuthenticatedRoleHandlerUnavailable ->
    (503, "interpreter-unavailable\n")
  AuthenticatedRoleHandlerResponseInvalid _ ->
    (500, "authenticated-handler-response-invalid\n")
