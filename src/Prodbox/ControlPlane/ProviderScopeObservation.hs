{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated, read-only observation of an exact retained scope receipt.
module Prodbox.ControlPlane.ProviderScopeObservation
  ( ProviderScopeObservationPayload (..)
  , ProviderScopeObservationResponse (..)
  , AuthorityProviderScopeObservationError (..)
  , authorityProviderScopeObservationAuthenticatedHandler
  , observeAuthorityProviderAwsScope
  ) where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Capacity.ControlPlaneReplayBudget (providerScopeObservationMaximumBytes)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter (AuthenticatedRoleHandler (..))
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionRepository)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli, CallerTestHarness))
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleProviderScopeObserveRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal
  ( ProviderAwsScopeReceiptError
  , VerifiedAuthorityProviderAwsScope
  , readRegisteredAuthorityProviderAwsScopeReceipt
  , verifySettledAuthorityProviderAwsScopeReceipt
  )
import Prodbox.ControlPlane.RequestAuthentication (verifiedCallerSlotPrincipal)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleProviderScopeObserve))
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data ProviderScopeObservationPayload = ProviderScopeObservationPayload
  { providerScopeObservationSubmissionKey :: !Text
  , providerScopeObservationOperation :: !OperationId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderScopeObservationResponse
  = ProviderScopeObserved !OperationId !Text
  | ProviderScopeObservationRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityProviderScopeObservationError
  = ProviderScopeObservationTransport !AuthenticatedClientError
  | ProviderScopeObservationInvalid !ControlPlaneResponseCodecError
  | ProviderScopeObservationStatus !Int
  | ProviderScopeObservationIdentityMismatch
  | ProviderScopeObservationProofInvalid !ProviderAwsScopeReceiptError
  deriving stock (Eq, Show)

observeAuthorityProviderAwsScope
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ClientSubmissionKey
  -> OperationId
  -> IO (Either AuthorityProviderScopeObservationError VerifiedAuthorityProviderAwsScope)
observeAuthorityProviderAwsScope transport key expected = do
  response <-
    callAuthenticatedClientTransport transport LifecycleProviderScopeObserveRoute $
      LazyByteString.toStrict $
        encodeControlPlaneRequest (ProviderScopeObservationPayload (clientSubmissionKeyText key) expected)
  pure $ do
    ControlPlaneResponse status body <- first ProviderScopeObservationTransport response
    decoded <-
      first ProviderScopeObservationInvalid $
        decodeControlPlaneResponse providerScopeObservationMaximumBytes (LazyByteString.fromStrict body)
    case decoded of
      ProviderScopeObserved actual receipt
        | status /= 200 -> Left (ProviderScopeObservationStatus status)
        | actual /= expected -> Left ProviderScopeObservationIdentityMismatch
        | otherwise ->
            first
              ProviderScopeObservationProofInvalid
              (verifySettledAuthorityProviderAwsScopeReceipt expected receipt)
      ProviderScopeObservationRefused -> Left (ProviderScopeObservationStatus status)

authorityProviderScopeObservationAuthenticatedHandler
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
authorityProviderScopeObservationAuthenticatedHandler repository fallback =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness fallback
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleProviderScopeObserve
      | callerAllowed (verifiedCallerSlotPrincipal caller) -> Just <$> observeScope caller body
      | otherwise -> pure (Just (ReplyForbidden, scopeBody ProviderScopeObservationRefused))
    _ -> authenticatedHandlerHandle fallback caller route body
  callerAllowed principal = case principal of
    CallerOperatorCli -> True
    CallerTestHarness -> True
    _ -> False

  observeScope caller body =
    case decodeControlPlaneRequest providerScopeObservationMaximumBytes (LazyByteString.fromStrict body) of
      Left _ -> pure (ReplyBadRequest, scopeBody ProviderScopeObservationRefused)
      Right (ProviderScopeObservationPayload rawKey operation) -> case mkClientSubmissionKey rawKey of
        Left _ -> pure (ReplyBadRequest, scopeBody ProviderScopeObservationRefused)
        Right key -> do
          observed <- readRegisteredAuthorityProviderAwsScopeReceipt repository caller key operation
          pure $ case observed of
            Left _ -> (ReplyServiceUnavailable, scopeBody ProviderScopeObservationRefused)
            Right receipt ->
              let response = scopeBody (ProviderScopeObserved operation receipt)
               in if ByteString.length response <= providerScopeObservationMaximumBytes
                    then (ReplyOk, response)
                    else (ReplyServiceUnavailable, scopeBody ProviderScopeObservationRefused)

  scopeBody = LazyByteString.toStrict . encodeControlPlaneResponse
