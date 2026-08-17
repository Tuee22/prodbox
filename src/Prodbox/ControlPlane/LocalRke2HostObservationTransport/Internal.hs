{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private host transport for the Establish mutation.  It performs
-- the canonical host observation only after the descriptor-bound Begin has
-- been validated, then submits the opaque candidate to the commit-only
-- Authority route.  There is deliberately no HTTP read-back operation.
module Prodbox.ControlPlane.LocalRke2HostObservationTransport.Internal
  ( LocalRke2HostObservationTransportError (..)
  , localRke2HostObservationEstablishBoundaryInternal
  , commitObservedLocalRke2HostObservationRemoteInternal
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
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleLocalRke2HostObservationRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.LocalRke2HostObservationEndpoint.Internal
  ( LocalRke2HostObservationEndpointResponseError
  , confirmLocalRke2HostObservationResponseInternal
  , decodeLocalRke2HostObservationEndpointResponseInternal
  , localRke2HostObservationCommitWireRequestInternal
  , localRke2HostObservationWireResponseStatus
  )
import Prodbox.ControlPlane.LocalRke2HostObservationRepository
  ( LocalRke2HostObservationCommitResult (..)
  , LocalRke2HostObservationRepositoryError (..)
  )
import Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal
  ( observeLocalRke2HealthyAfterEstablishBeginInternal
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Teardown.Execution (TeardownExecutionContext)
import Prodbox.Lifecycle.Teardown.Program (RecoverySurfaceWitness)
import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal
  ( RecoveryPlaneEstablishBoundary (..)
  , RecoveryPlaneEstablishResult (..)
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data LocalRke2HostObservationTransportError
  = LocalRke2HostObservationTransportObservationFailed
      !LocalRke2HostObservationRepositoryError
  | LocalRke2HostObservationTransportCallFailed !Text
  | LocalRke2HostObservationTransportResponseInvalid !Text
  | LocalRke2HostObservationTransportResponseRefused
      !LocalRke2HostObservationEndpointResponseError
  | LocalRke2HostObservationTransportHttpStatusMismatch !Int !Int
  deriving stock (Eq, Show)

-- | Closed production Establish boundary.  The opaque handle, witness, and
-- typed context are passed by the already validated interpreter invocation;
-- callers cannot submit a cached observation captured before Begin.
localRke2HostObservationEstablishBoundaryInternal
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RecoveryPlaneEstablishBoundary IO
localRke2HostObservationEstablishBoundaryInternal transport =
  RecoveryPlaneEstablishBoundary $ \bound witness context _ _ -> do
    attempted <-
      commitObservedLocalRke2HostObservationRemoteInternal
        transport
        bound
        witness
        context
    pure $ case attempted of
      Left err -> transportFailureToEstablish err
      Right result -> commitResultToEstablish result

commitObservedLocalRke2HostObservationRemoteInternal
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> IO
       ( Either
           LocalRke2HostObservationTransportError
           LocalRke2HostObservationCommitResult
       )
commitObservedLocalRke2HostObservationRemoteInternal transport bound witness context = do
  observed <- observeLocalRke2HealthyAfterEstablishBeginInternal bound witness context
  case first LocalRke2HostObservationTransportObservationFailed observed of
    Left err -> pure (Left err)
    Right candidate -> do
      let request = localRke2HostObservationCommitWireRequestInternal candidate
      attempted <-
        callAuthenticatedClientTransport
          transport
          LifecycleLocalRke2HostObservationRoute
          (LazyByteString.toStrict (encodeControlPlaneRequest request))
      pure $ do
        ControlPlaneResponse status body <-
          first
            ( LocalRke2HostObservationTransportCallFailed
                . bounded
                . Text.pack
                . show
            )
            attempted
        response <-
          first
            ( LocalRke2HostObservationTransportResponseInvalid
                . bounded
                . Text.pack
                . show
            )
            (decodeLocalRke2HostObservationEndpointResponseInternal body)
        confirmed <-
          first
            LocalRke2HostObservationTransportResponseRefused
            (confirmLocalRke2HostObservationResponseInternal request response)
        let expectedStatus =
              replyStatusCode (localRke2HostObservationWireResponseStatus response)
        if status == expectedStatus
          then Right confirmed
          else
            Left
              ( LocalRke2HostObservationTransportHttpStatusMismatch
                  expectedStatus
                  status
              )

commitResultToEstablish
  :: LocalRke2HostObservationCommitResult -> RecoveryPlaneEstablishResult
commitResultToEstablish result = case result of
  LocalRke2HostObservationCommitCreated -> RecoveryPlaneEstablishApplied
  LocalRke2HostObservationCommitExactReplay -> RecoveryPlaneEstablishApplied
  LocalRke2HostObservationCommitConflict ->
    RecoveryPlaneEstablishConflict "local RKE2 Healthy receipt conflicts"
  LocalRke2HostObservationCommitResponseLost failure ->
    RecoveryPlaneEstablishResponseLost (bounded (render failure))
  LocalRke2HostObservationCommitUnavailable failure ->
    RecoveryPlaneEstablishUnavailable (bounded (render failure))

transportFailureToEstablish
  :: LocalRke2HostObservationTransportError -> RecoveryPlaneEstablishResult
transportFailureToEstablish err = case err of
  LocalRke2HostObservationTransportObservationFailed observationError ->
    case observationError of
      LocalRke2HostObservationRepositoryStateUnobservable {} ->
        RecoveryPlaneEstablishUnavailable (render observationError)
      LocalRke2HostObservationRepositoryUnobservable {} ->
        RecoveryPlaneEstablishUnavailable (render observationError)
      _ -> RecoveryPlaneEstablishRefused (render observationError)
  -- Once a POST is issued, a missing/invalid/mismatched response cannot prove
  -- the CAS did not apply.  It is therefore effect-unconfirmed, not refused.
  LocalRke2HostObservationTransportCallFailed detail ->
    RecoveryPlaneEstablishResponseLost detail
  LocalRke2HostObservationTransportResponseInvalid detail ->
    RecoveryPlaneEstablishResponseLost detail
  LocalRke2HostObservationTransportHttpStatusMismatch expected actual ->
    RecoveryPlaneEstablishResponseLost
      ( "host-observation HTTP status mismatch: expected "
          <> Text.pack (show expected)
          <> ", got "
          <> Text.pack (show actual)
      )
  LocalRke2HostObservationTransportResponseRefused detail ->
    RecoveryPlaneEstablishRefused (render detail)

render :: (Show value) => value -> Text
render = bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024
