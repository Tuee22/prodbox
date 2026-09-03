{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority endpoint for the secret-free Admin
-- Action state machine. Elevated credentials never enter these request or
-- response types; they are attached later to the exact attested Job stdin.
module Prodbox.ControlPlane.AdminActionEndpoint
  ( AdminActionAuthorityRequest (..)
  , AdminActionAuthorityResponse (..)
  , AdminActionRepositoryResolver
  , adminActionAuthenticatedHandler
  , adminActionEndpointMaximumBytes
  , adminActionEndpointResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (..))
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  , verifiedCallerSlotPrincipal
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , layerRoleReadinessSource
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAdminAction)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionAuthorityBoundary
  , AdminActionAuthorityError (..)
  , AdminActionAuthorityRepository
  , AdminActionPodObservation
  , AdminActionPrepareRequest (..)
  , authorizeAdminAction
  , completeAdminAction
  , observeAdminAction
  , prepareAdminAction
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionBackupReceipt
  , AdminActionExecutionState
  , AdminActionPermitCore
  , AdminActionReceipt
  , encodeSignedAdminActionPermit
  )

data AdminActionAuthorityRequest
  = PrepareAdminAction !AdminActionPrepareRequest
  | AuthorizeAdminAction !Text !AdminActionPodObservation
  | CompleteAdminAction !Text !AdminActionReceipt
  | ObserveAdminAction !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionAuthorityResponse
  = AdminActionPrepared !AdminActionPermitCore !AdminActionBackupReceipt
  | AdminActionAuthorized !ByteString
  | AdminActionCompleted !AdminActionReceipt
  | AdminActionObserved !AdminActionExecutionState
  | AdminActionRefused !Text
  | AdminActionUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

type AdminActionRepositoryResolver m revision =
  Text -> Either Text (AdminActionAuthorityRepository m revision)

adminActionEndpointMaximumBytes :: Int
adminActionEndpointMaximumBytes = 256 * 1024

adminActionEndpointResponseMaximumBytes :: Int
adminActionEndpointResponseMaximumBytes = 256 * 1024

adminActionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> AdminActionRepositoryResolver m revision
  -> AdminActionAuthorityBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
adminActionAuthenticatedHandler maximumBytes readiness resolveRepository boundary fallback =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness =
        layerRoleReadinessSource readiness (authenticatedHandlerReadiness fallback)
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleAdminAction -> Just <$> serve caller body
    _ -> authenticatedHandlerHandle fallback caller route body

  serve caller body
    | not (adminCallerAllowed caller) =
        pure (ReplyForbidden, responseBody (AdminActionRefused "caller-refused"))
    | otherwise = case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
        Left _ -> pure (ReplyBadRequest, responseBody (AdminActionRefused "request-codec-rejected"))
        Right request -> do
          response <- runRequest request
          pure (responseStatus response, responseBody response)

  runRequest request = case request of
    PrepareAdminAction prepareRequest ->
      withRepository (adminActionPrepareOperationId prepareRequest) $ \repository -> do
        result <- prepareAdminAction repository boundary prepareRequest
        pure $ case result of
          Left err -> responseForError err
          Right (core, backup) -> AdminActionPrepared core backup
    AuthorizeAdminAction operationId observation ->
      withRepository operationId $ \repository -> do
        result <- authorizeAdminAction repository boundary operationId observation
        pure $ case result of
          Left err -> responseForError err
          Right permit -> AdminActionAuthorized (encodeSignedAdminActionPermit permit)
    CompleteAdminAction operationId receipt ->
      withRepository operationId $ \repository -> do
        result <- completeAdminAction repository operationId receipt
        pure $ case result of
          Left err -> responseForError err
          Right confirmed -> AdminActionCompleted confirmed
    ObserveAdminAction operationId ->
      withRepository operationId $ \repository -> do
        result <- observeAdminAction repository operationId
        pure $ case result of
          Left err -> responseForError err
          Right state -> AdminActionObserved state

  withRepository operationId action = case resolveRepository operationId of
    Left _ -> pure (AdminActionRefused "operation-coordinate-rejected")
    Right repository -> action repository

responseForError :: AdminActionAuthorityError -> AdminActionAuthorityResponse
responseForError err = case err of
  AdminActionAuthorityUnavailable _ -> unavailable "authority-unavailable"
  AdminActionAuthorityBackupFailed _ -> unavailable "backup-readback-unavailable"
  AdminActionAuthoritySignerFailed _ -> unavailable "signer-unavailable"
  AdminActionAuthorityCommitFailed _ -> unavailable "commit-readback-unavailable"
  AdminActionAuthoritySignerGenerationChanged _ _ -> refused "signer-generation-changed"
  AdminActionAuthorityProtocolRejected _ -> refused "protocol-rejected"
  AdminActionAuthorityOperationMismatch -> refused "operation-mismatch"
  AdminActionAuthorityStateConflict -> refused "state-conflict"
 where
  refused = AdminActionRefused
  unavailable = AdminActionUnavailable

responseStatus :: AdminActionAuthorityResponse -> ReplyStatus
responseStatus response = case response of
  AdminActionPrepared _ _ -> ReplyOk
  AdminActionAuthorized _ -> ReplyOk
  AdminActionCompleted _ -> ReplyOk
  AdminActionObserved _ -> ReplyOk
  AdminActionRefused _ -> ReplyConflict
  AdminActionUnavailable _ -> ReplyServiceUnavailable

responseBody :: AdminActionAuthorityResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

adminCallerAllowed :: VerifiedCallerSlot -> Bool
adminCallerAllowed caller = case verifiedCallerSlotPrincipal caller of
  CallerOperatorCli -> True
  CallerTestHarness -> True
  CallerAdminActionRunner -> False
  CallerCredentialProvisioner -> False
  CallerCredentialProvisionerCompletion -> False
  CallerService _ -> False
