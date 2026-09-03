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
  , AuthenticatedRolePlainResponseCause (..)
  , AuthenticatedRolePlainResponseObservation (..)
  , allAuthenticatedRolePlainResponseCauses
  , allAuthenticatedRolePlainResponseObservations
  , authenticatedRolePlainResponse
  , classifyAuthenticatedRolePlainResponse
  , renderAuthenticatedRolePlainResponseObservation
  , authenticatedRoleInterpreter

    -- * Stable total HTTP projections
  , authenticatedServerErrorResponse
  , replayProtectedResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
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
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
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

-- | Every static plaintext response authored by the authenticated-role
-- interpreter. Response bytes are confined to the total projection below;
-- downstream diagnostics retain only the closed observation.
data AuthenticatedRolePlainResponseCause
  = AuthenticatedRoleFrameRefused
  | AuthenticatedRoleRouteRoleMismatch
  | AuthenticatedRoleScopeUnavailable
  | AuthenticatedRoleEpochUnavailable
  | AuthenticatedRoleTimeUnavailable
  | AuthenticatedRoleTrustUnavailable
  | AuthenticatedRoleTrustRoleMismatch
  | AuthenticatedRoleAuthenticationRefused
  | AuthenticatedRoleAuthenticationAmbiguous
  | AuthenticatedRoleAuthenticationBindingInvalid
  | AuthenticatedRoleReplayAttemptUnavailable
  | AuthenticatedRoleReplayInFlight
  | AuthenticatedRoleReplayTombstoned
  | AuthenticatedRoleReplayDigestConflict
  | AuthenticatedRoleReplayExpired
  | AuthenticatedRoleReplayCapacityExhausted
  | AuthenticatedRoleReplayUnavailable
  | AuthenticatedRoleReplayAttemptsExhausted
  | AuthenticatedRoleReplayCompletionUnconfirmed
  | AuthenticatedRoleInterpreterUnavailable
  | AuthenticatedRoleHandlerInvalidResponse
  deriving stock (Bounded, Enum, Eq, Show)

data AuthenticatedRolePlainResponseObservation
  = AuthenticatedRolePlainResponseKnown !AuthenticatedRolePlainResponseCause
  | AuthenticatedRolePlainResponseOther
  deriving stock (Eq, Show)

allAuthenticatedRolePlainResponseCauses :: [AuthenticatedRolePlainResponseCause]
allAuthenticatedRolePlainResponseCauses = [minBound .. maxBound]

allAuthenticatedRolePlainResponseObservations :: [AuthenticatedRolePlainResponseObservation]
allAuthenticatedRolePlainResponseObservations =
  (AuthenticatedRolePlainResponseKnown <$> allAuthenticatedRolePlainResponseCauses)
    <> [AuthenticatedRolePlainResponseOther]

-- | The single source of truth for the interpreter's static response pairs.
authenticatedRolePlainResponse
  :: AuthenticatedRolePlainResponseCause -> (ReplyStatus, ByteString)
authenticatedRolePlainResponse cause = case cause of
  AuthenticatedRoleFrameRefused ->
    (ReplyBadRequest, "authenticated-frame-refused\n")
  AuthenticatedRoleRouteRoleMismatch ->
    (ReplyInternalError, "authenticated-route-role-mismatch\n")
  AuthenticatedRoleScopeUnavailable ->
    (ReplyServiceUnavailable, "authenticated-scope-unavailable\n")
  AuthenticatedRoleEpochUnavailable ->
    (ReplyServiceUnavailable, "authenticated-epoch-unavailable\n")
  AuthenticatedRoleTimeUnavailable ->
    (ReplyServiceUnavailable, "authenticated-time-unavailable\n")
  AuthenticatedRoleTrustUnavailable ->
    (ReplyServiceUnavailable, "authenticated-trust-unavailable\n")
  AuthenticatedRoleTrustRoleMismatch ->
    (ReplyInternalError, "authenticated-trust-role-mismatch\n")
  AuthenticatedRoleAuthenticationRefused ->
    (ReplyUnauthorized, "authentication-refused\n")
  AuthenticatedRoleAuthenticationAmbiguous ->
    (ReplyUnauthorized, "authentication-ambiguous\n")
  AuthenticatedRoleAuthenticationBindingInvalid ->
    (ReplyInternalError, "authentication-binding-invalid\n")
  AuthenticatedRoleReplayAttemptUnavailable ->
    (ReplyServiceUnavailable, "authenticated-replay-attempt-unavailable\n")
  AuthenticatedRoleReplayInFlight ->
    (ReplyConflict, "authenticated-replay-in-flight\n")
  AuthenticatedRoleReplayTombstoned ->
    (ReplyConflict, "authenticated-replay-tombstoned\n")
  AuthenticatedRoleReplayDigestConflict ->
    (ReplyConflict, "authenticated-replay-digest-conflict\n")
  AuthenticatedRoleReplayExpired ->
    (ReplyRequestTimeout, "authenticated-replay-expired\n")
  AuthenticatedRoleReplayCapacityExhausted ->
    (ReplyServiceUnavailable, "authenticated-replay-capacity-exhausted\n")
  AuthenticatedRoleReplayUnavailable ->
    (ReplyServiceUnavailable, "authenticated-replay-unavailable\n")
  AuthenticatedRoleReplayAttemptsExhausted ->
    (ReplyServiceUnavailable, "authenticated-replay-attempts-exhausted\n")
  AuthenticatedRoleReplayCompletionUnconfirmed ->
    (ReplyServiceUnavailable, "authenticated-replay-completion-unconfirmed\n")
  AuthenticatedRoleInterpreterUnavailable ->
    (ReplyServiceUnavailable, "interpreter-unavailable\n")
  AuthenticatedRoleHandlerInvalidResponse ->
    (ReplyInternalError, "authenticated-handler-response-invalid\n")

classifyAuthenticatedRolePlainResponse
  :: Int -> ByteString -> AuthenticatedRolePlainResponseObservation
classifyAuthenticatedRolePlainResponse status body =
  maybe
    AuthenticatedRolePlainResponseOther
    AuthenticatedRolePlainResponseKnown
    (find matches allAuthenticatedRolePlainResponseCauses)
 where
  matches cause =
    let (authoredStatus, authoredBody) = authenticatedRolePlainResponse cause
     in replyStatusCode authoredStatus == status && authoredBody == body

renderAuthenticatedRolePlainResponseObservation
  :: AuthenticatedRolePlainResponseObservation -> Text
renderAuthenticatedRolePlainResponseObservation observation = case observation of
  AuthenticatedRolePlainResponseKnown cause -> case cause of
    AuthenticatedRoleFrameRefused -> "frame-refused"
    AuthenticatedRoleRouteRoleMismatch -> "route-role-mismatch"
    AuthenticatedRoleScopeUnavailable -> "scope-unavailable"
    AuthenticatedRoleEpochUnavailable -> "epoch-unavailable"
    AuthenticatedRoleTimeUnavailable -> "time-unavailable"
    AuthenticatedRoleTrustUnavailable -> "trust-unavailable"
    AuthenticatedRoleTrustRoleMismatch -> "trust-role-mismatch"
    AuthenticatedRoleAuthenticationRefused -> "authentication-refused"
    AuthenticatedRoleAuthenticationAmbiguous -> "authentication-ambiguous"
    AuthenticatedRoleAuthenticationBindingInvalid -> "authentication-binding-invalid"
    AuthenticatedRoleReplayAttemptUnavailable -> "replay-attempt-unavailable"
    AuthenticatedRoleReplayInFlight -> "replay-in-flight"
    AuthenticatedRoleReplayTombstoned -> "replay-tombstoned"
    AuthenticatedRoleReplayDigestConflict -> "replay-digest-conflict"
    AuthenticatedRoleReplayExpired -> "replay-expired"
    AuthenticatedRoleReplayCapacityExhausted -> "replay-capacity-exhausted"
    AuthenticatedRoleReplayUnavailable -> "replay-unavailable"
    AuthenticatedRoleReplayAttemptsExhausted -> "replay-attempts-exhausted"
    AuthenticatedRoleReplayCompletionUnconfirmed -> "replay-completion-unconfirmed"
    AuthenticatedRoleInterpreterUnavailable -> "interpreter-unavailable"
    AuthenticatedRoleHandlerInvalidResponse -> "handler-response-invalid"
  AuthenticatedRolePlainResponseOther -> "other"

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
            Left _ ->
              pure
                ( Just
                    ( authenticatedRolePlainResponse
                        AuthenticatedRoleReplayAttemptUnavailable
                    )
                )
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
authenticatedServerErrorResponse = authenticatedRolePlainResponse . serverErrorCause

serverErrorCause :: AuthenticatedServerError -> AuthenticatedRolePlainResponseCause
serverErrorCause err = case err of
  AuthenticatedServerFrameFailed _ ->
    AuthenticatedRoleFrameRefused
  AuthenticatedServerRouteRoleMismatch {} ->
    AuthenticatedRoleRouteRoleMismatch
  AuthenticatedServerScopeUnavailable _ ->
    AuthenticatedRoleScopeUnavailable
  AuthenticatedServerEpochUnavailable _ ->
    AuthenticatedRoleEpochUnavailable
  AuthenticatedServerTimeUnavailable _ ->
    AuthenticatedRoleTimeUnavailable
  AuthenticatedServerTrustRegistryUnavailable _ ->
    AuthenticatedRoleTrustUnavailable
  AuthenticatedServerTrustRegistryRoleMismatch {} ->
    AuthenticatedRoleTrustRoleMismatch
  AuthenticatedServerRequestAuthenticationFailed _ ->
    AuthenticatedRoleAuthenticationRefused
  AuthenticatedServerRequestAuthenticationAmbiguous ->
    AuthenticatedRoleAuthenticationAmbiguous
  AuthenticatedServerBindingFailed _ ->
    AuthenticatedRoleAuthenticationBindingInvalid

replayProtectedResponse
  :: ReplayProtectedResult AuthenticatedRoleHandlerFailure
  -> (ReplyStatus, ByteString)
replayProtectedResponse result = case result of
  ReplayProtectedExecuted response -> replayResponse response
  ReplayProtectedRecovered response -> replayResponse response
  ReplayProtectedInFlight -> authenticatedRolePlainResponse AuthenticatedRoleReplayInFlight
  ReplayProtectedTombstoned ->
    authenticatedRolePlainResponse AuthenticatedRoleReplayTombstoned
  ReplayProtectedDigestConflict ->
    authenticatedRolePlainResponse AuthenticatedRoleReplayDigestConflict
  ReplayProtectedExpired -> authenticatedRolePlainResponse AuthenticatedRoleReplayExpired
  ReplayProtectedCapacityExhausted ->
    authenticatedRolePlainResponse AuthenticatedRoleReplayCapacityExhausted
  ReplayProtectedUnavailable _ ->
    authenticatedRolePlainResponse AuthenticatedRoleReplayUnavailable
  ReplayProtectedAttemptsExhausted ->
    authenticatedRolePlainResponse AuthenticatedRoleReplayAttemptsExhausted
  ReplayProtectedEffectFailed failure -> handlerFailureResponse failure
  ReplayProtectedCompletionUnconfirmed _ ->
    authenticatedRolePlainResponse AuthenticatedRoleReplayCompletionUnconfirmed

replayResponse :: ReplayResponse -> (ReplyStatus, ByteString)
replayResponse response =
  (replayResponseStatus response, replayResponseBody response)

handlerFailureResponse :: AuthenticatedRoleHandlerFailure -> (ReplyStatus, ByteString)
handlerFailureResponse = authenticatedRolePlainResponse . handlerFailureCause

handlerFailureCause
  :: AuthenticatedRoleHandlerFailure -> AuthenticatedRolePlainResponseCause
handlerFailureCause failure = case failure of
  AuthenticatedRoleHandlerUnavailable -> AuthenticatedRoleInterpreterUnavailable
  AuthenticatedRoleHandlerResponseInvalid _ -> AuthenticatedRoleHandlerInvalidResponse
