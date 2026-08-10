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
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Lease (AuthorityDuration)
import Prodbox.Runtime.Role (RuntimeRole)

data AuthenticatedRoleHandler m = AuthenticatedRoleHandler
  { authenticatedHandlerReadiness :: !RoleReadinessSource
  , authenticatedHandlerHandle
      :: VerifiedCallerSlot
      -> ControlPlaneRoute
      -> ByteString
      -> m (Maybe (ReplyStatus, ByteString))
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
            Left _ -> pure (Just (ReplyServiceUnavailable, "authenticated-replay-attempt-unavailable\n"))
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

authenticatedServerErrorResponse :: AuthenticatedServerError -> (ReplyStatus, ByteString)
authenticatedServerErrorResponse err = case err of
  AuthenticatedServerFrameFailed _ ->
    (ReplyBadRequest, "authenticated-frame-refused\n")
  AuthenticatedServerRouteRoleMismatch {} ->
    (ReplyInternalError, "authenticated-route-role-mismatch\n")
  AuthenticatedServerScopeUnavailable _ ->
    (ReplyServiceUnavailable, "authenticated-scope-unavailable\n")
  AuthenticatedServerEpochUnavailable _ ->
    (ReplyServiceUnavailable, "authenticated-epoch-unavailable\n")
  AuthenticatedServerTimeUnavailable _ ->
    (ReplyServiceUnavailable, "authenticated-time-unavailable\n")
  AuthenticatedServerTrustRegistryUnavailable _ ->
    (ReplyServiceUnavailable, "authenticated-trust-unavailable\n")
  AuthenticatedServerTrustRegistryRoleMismatch {} ->
    (ReplyInternalError, "authenticated-trust-role-mismatch\n")
  AuthenticatedServerRequestAuthenticationFailed _ ->
    (ReplyUnauthorized, "authentication-refused\n")
  AuthenticatedServerRequestAuthenticationAmbiguous ->
    (ReplyUnauthorized, "authentication-ambiguous\n")
  AuthenticatedServerBindingFailed _ ->
    (ReplyInternalError, "authentication-binding-invalid\n")

replayProtectedResponse
  :: ReplayProtectedResult AuthenticatedRoleHandlerFailure
  -> (ReplyStatus, ByteString)
replayProtectedResponse result = case result of
  ReplayProtectedExecuted response -> replayResponse response
  ReplayProtectedRecovered response -> replayResponse response
  ReplayProtectedInFlight -> (ReplyConflict, "authenticated-replay-in-flight\n")
  ReplayProtectedTombstoned -> (ReplyConflict, "authenticated-replay-tombstoned\n")
  ReplayProtectedDigestConflict -> (ReplyConflict, "authenticated-replay-digest-conflict\n")
  ReplayProtectedExpired -> (ReplyRequestTimeout, "authenticated-replay-expired\n")
  ReplayProtectedCapacityExhausted ->
    (ReplyServiceUnavailable, "authenticated-replay-capacity-exhausted\n")
  ReplayProtectedUnavailable _ ->
    (ReplyServiceUnavailable, "authenticated-replay-unavailable\n")
  ReplayProtectedAttemptsExhausted ->
    (ReplyServiceUnavailable, "authenticated-replay-attempts-exhausted\n")
  ReplayProtectedEffectFailed failure -> handlerFailureResponse failure
  ReplayProtectedCompletionUnconfirmed _ ->
    (ReplyServiceUnavailable, "authenticated-replay-completion-unconfirmed\n")

replayResponse :: ReplayResponse -> (ReplyStatus, ByteString)
replayResponse response =
  (replayResponseStatus response, replayResponseBody response)

handlerFailureResponse :: AuthenticatedRoleHandlerFailure -> (ReplyStatus, ByteString)
handlerFailureResponse failure = case failure of
  AuthenticatedRoleHandlerUnavailable ->
    (ReplyServiceUnavailable, "interpreter-unavailable\n")
  AuthenticatedRoleHandlerResponseInvalid _ ->
    (ReplyInternalError, "authenticated-handler-response-invalid\n")
