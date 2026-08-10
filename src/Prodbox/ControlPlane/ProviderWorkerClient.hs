{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated transport for the signed Provider committed-intent lane.
-- Only the Lifecycle Authority can reach this route; the body remains the
-- independently signed, canonical inner intent verified by the worker.
module Prodbox.ControlPlane.ProviderWorkerClient
  ( ProviderWorkerResponse (..)
  , ProviderWorkerClientError (..)
  , providerWorkerResponseMaximumBytes
  , providerWorkerExecutionAuthenticatedHandler
  , dispatchProviderCommittedIntent
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerService)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (ProviderWorkApplyRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult
  , ProviderWorkerExecutionBoundary
  , admitProviderCommittedIntent
  , executeVerifiedProviderIntent
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( verifiedCallerSlotPrincipal
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (ProviderWorkApply)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )

data ProviderWorkerResponse
  = ProviderWorkerExecuted !ProviderIntentExecutionResult
  | ProviderWorkerAdmissionRefused !Text
  | ProviderWorkerExecutionFailed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderWorkerClientError
  = ProviderWorkerTransportFailed !AuthenticatedClientError
  | ProviderWorkerResponseInvalid !ControlPlaneResponseCodecError
  | ProviderWorkerResponseStatusMismatch !Int
  | ProviderWorkerRemoteRefused !Int !Text
  deriving stock (Eq, Show)

providerWorkerResponseMaximumBytes :: Int
providerWorkerResponseMaximumBytes = 64 * 1024

providerWorkerExecutionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> ProviderWorkerExecutionBoundary m session
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
providerWorkerExecutionAuthenticatedHandler maximumBytes boundary fallback =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness fallback
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    ProviderWorkApply
      | verifiedCallerSlotPrincipal caller
          == CallerService LifecycleAuthorityRuntime ->
          Just <$> serve body
      | otherwise ->
          pure (Just (ReplyForbidden, responseBody (ProviderWorkerAdmissionRefused "caller-refused")))
    _ -> authenticatedHandlerHandle fallback caller route body

  serve body = do
    admitted <- admitProviderCommittedIntent maximumBytes boundary body
    case admitted of
      Left err ->
        pure
          ( ReplyConflict
          , responseBody
              (ProviderWorkerAdmissionRefused (Text.pack (show err)))
          )
      Right verified -> do
        executed <- executeVerifiedProviderIntent boundary verified
        pure $ case executed of
          Left err ->
            ( ReplyServiceUnavailable
            , responseBody
                (ProviderWorkerExecutionFailed (Text.pack (show err)))
            )
          Right result -> (ReplyOk, responseBody (ProviderWorkerExecuted result))

  responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

dispatchProviderCommittedIntent
  :: AuthenticatedClientTransport 'ProviderWorkerRuntime
  -> ByteString
  -> IO (Either ProviderWorkerClientError ProviderIntentExecutionResult)
dispatchProviderCommittedIntent transport body = do
  response <-
    callAuthenticatedClientTransport transport ProviderWorkApplyRoute body
  pure $ do
    ControlPlaneResponse status responseBytes <-
      first ProviderWorkerTransportFailed response
    decoded <-
      first
        ProviderWorkerResponseInvalid
        ( decodeControlPlaneResponse
            providerWorkerResponseMaximumBytes
            (LazyByteString.fromStrict responseBytes)
        )
    case decoded of
      ProviderWorkerExecuted result
        | status == 200 -> Right result
        | otherwise -> Left (ProviderWorkerResponseStatusMismatch status)
      ProviderWorkerAdmissionRefused detail ->
        Left (ProviderWorkerRemoteRefused status detail)
      ProviderWorkerExecutionFailed detail ->
        Left (ProviderWorkerRemoteRefused status detail)
