{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- | Authenticated host-side recovery-plane client.  The only callable
-- operations carry the durable run/current-operation/current-attempt
-- identity.  Component observations and proof constructors are absent from
-- this surface.
module Prodbox.ControlPlane.RecoveryPlaneTransportClient
  ( RecoveryPlaneAuthorityClient
  , RecoveryPlaneAuthorityClientError (..)
  , lifecycleAuthorityRecoveryPlaneAuthenticatedClient
  , executeRecoveryPlaneInitialReadBackRemote
  , executeRecoveryPlaneFinalDispositionRemote
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleRecoveryPlaneRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.RecoveryPlaneEndpoint
  ( RecoveryPlaneEndpointResponseError
  , RecoveryPlaneWireRequest
  , confirmRecoveryPlaneResponse
  , decodeRecoveryPlaneEndpointResponse
  , recoveryPlaneFinalDispositionWireRequest
  , recoveryPlaneInitialReadBackWireRequest
  , recoveryPlaneWireResponseStatus
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupNodeOutcome
  , CleanupOperationId
  , CleanupRunId
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype RecoveryPlaneAuthorityClient m
  = RecoveryPlaneAuthorityClient
      ( RecoveryPlaneWireRequest
        -> m (Either RecoveryPlaneAuthorityClientError CleanupNodeOutcome)
      )

data RecoveryPlaneAuthorityClientError
  = RecoveryPlaneAuthorityClientTransportFailed !Text
  | RecoveryPlaneAuthorityClientResponseInvalid !Text
  | RecoveryPlaneAuthorityClientHttpStatusMismatch !Int !Int
  | RecoveryPlaneAuthorityClientResponseRefused !RecoveryPlaneEndpointResponseError
  deriving stock (Eq, Show)

lifecycleAuthorityRecoveryPlaneAuthenticatedClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RecoveryPlaneAuthorityClient IO
lifecycleAuthorityRecoveryPlaneAuthenticatedClient transport =
  RecoveryPlaneAuthorityClient $ \request -> do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleRecoveryPlaneRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first
          ( RecoveryPlaneAuthorityClientTransportFailed
              . bounded
              . Text.pack
              . show
          )
          attempted
      response <-
        first
          ( RecoveryPlaneAuthorityClientResponseInvalid
              . bounded
              . Text.pack
              . show
          )
          (decodeRecoveryPlaneEndpointResponse body)
      let expectedStatus = replyStatusCode (recoveryPlaneWireResponseStatus response)
      if status == expectedStatus
        then
          first
            RecoveryPlaneAuthorityClientResponseRefused
            (confirmRecoveryPlaneResponse request response)
        else
          Left
            ( RecoveryPlaneAuthorityClientHttpStatusMismatch
                expectedStatus
                status
            )

executeRecoveryPlaneInitialReadBackRemote
  :: RecoveryPlaneAuthorityClient m
  -> CleanupRunId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> m (Either RecoveryPlaneAuthorityClientError CleanupNodeOutcome)
executeRecoveryPlaneInitialReadBackRemote
  (RecoveryPlaneAuthorityClient execute)
  runId
  operationId
  attemptId =
    execute
      (recoveryPlaneInitialReadBackWireRequest runId operationId attemptId)

executeRecoveryPlaneFinalDispositionRemote
  :: RecoveryPlaneAuthorityClient m
  -> CleanupRunId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> m (Either RecoveryPlaneAuthorityClientError CleanupNodeOutcome)
executeRecoveryPlaneFinalDispositionRemote
  (RecoveryPlaneAuthorityClient execute)
  runId
  operationId
  attemptId =
    execute
      (recoveryPlaneFinalDispositionWireRequest runId operationId attemptId)

bounded :: Text -> Text
bounded = Text.take 1024
