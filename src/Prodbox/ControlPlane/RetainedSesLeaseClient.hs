{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Role-indexed client capability for the Lifecycle Authority's one retained
-- @aws-ses@ lease.  The public capability has observe/initialize/replace only;
-- it cannot name another object or call a generic object-store route.
module Prodbox.ControlPlane.RetainedSesLeaseClient
  ( RetainedSesLeaseAuthority (..)
  , retainedSesLeaseMaximumResponseBytes
  , lifecycleAuthorityRetainedSesLease
  , retainedSesLeaseModelBCasAdapter
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleRetainedSesLeaseRoute)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.RetainedSesLeaseEndpoint
  ( RetainedSesLeaseRequest (..)
  , RetainedSesLeaseResponse (..)
  , RetainedSesLeaseWireCasResult (..)
  , RetainedSesLeaseWireObservation (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkModelBObjectVersion
  , modelBObjectVersionText
  )
import Prodbox.Lifecycle.Lease
  ( LeaseGrant
  , LeaseKey
  , LeasePolicy
  , LeaseProjection
  , decodeLeaseProjection
  , encodeLeaseProjection
  , leaseGrantKey
  , leaseObjectCoordinate
  , leaseProjectionActiveGrant
  , leaseProjectionReleasedPredecessor
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

-- | Closed client capability.  The exact coordinate is absent from every
-- method, so callers cannot redirect an operation to arbitrary Model-B state.
data RetainedSesLeaseAuthority m = RetainedSesLeaseAuthority
  { observeRetainedSesLease :: !(m (ModelBObservation LeaseProjection))
  , initializeRetainedSesLease
      :: !(LeaseProjection -> m (ModelBCasResult LeaseProjection))
  , replaceRetainedSesLease
      :: !( ModelBObjectVersion
            -> LeaseProjection
            -> m (ModelBCasResult LeaseProjection)
          )
  }

retainedSesLeaseMaximumResponseBytes :: Int
retainedSesLeaseMaximumResponseBytes = 32 * 1024

lifecycleAuthorityRetainedSesLease
  :: LeasePolicy
  -> LeaseKey
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RetainedSesLeaseAuthority IO
lifecycleAuthorityRetainedSesLease policy expectedKey transport =
  RetainedSesLeaseAuthority
    { observeRetainedSesLease = do
        response <- call ObserveRetainedSesLease
        pure $ case response of
          Left detail -> ModelBEndpointUnready detail
          Right (RetainedSesLeaseObservation observation) ->
            decodeObservation policy expectedKey observation
          Right unexpected ->
            ModelBCorrupt
              ("Lifecycle Authority returned the wrong retained-lease response: " <> responseToken unexpected)
    , initializeRetainedSesLease = \projection ->
        callCas
          policy
          expectedKey
          (InitializeRetainedSesLease (encodeLeaseProjection projection))
    , replaceRetainedSesLease = \version projection ->
        callCas
          policy
          expectedKey
          ( ReplaceRetainedSesLease
              (modelBObjectVersionText version)
              (encodeLeaseProjection projection)
          )
    }
 where
  call request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleRetainedSesLeaseRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <- first (Text.pack . show) attempted
      if status /= 200
        then Left ("Lifecycle Authority retained-lease HTTP status " <> Text.pack (show status))
        else
          first
            (Text.pack . show)
            ( decodeControlPlaneResponse
                retainedSesLeaseMaximumResponseBytes
                (LazyByteString.fromStrict body)
            )

  callCas leasePolicy leaseKey request = do
    response <- call request
    pure $ case response of
      Left detail -> ModelBCasEndpointUnready detail
      Right (RetainedSesLeaseCas result) ->
        decodeCasResult leasePolicy leaseKey result
      Right (RetainedSesLeaseProjectionRefused detail) ->
        ModelBCasRefusedCorrupt detail
      Right unexpected ->
        ModelBCasRefusedCorrupt
          ("Lifecycle Authority returned the wrong retained-lease response: " <> responseToken unexpected)

-- | Compatibility only at the pure lease-interpreter boundary.  It accepts
-- exactly the coordinate derived at construction and projects initialize /
-- replace onto the closed client methods.  A different coordinate or either
-- guarded generic CAS arm is refused locally and never reaches the wire.
retainedSesLeaseModelBCasAdapter
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> RetainedSesLeaseAuthority IO
  -> Either
       AuthorityCoordinateError
       (ModelBCasAdapter 'ClusterRetained IO LeaseProjection)
retainedSesLeaseModelBCasAdapter authority key capability = do
  exactCoordinate <- leaseObjectCoordinate authority key
  pure
    ModelBCasAdapter
      { modelBObserve = observe exactCoordinate
      , modelBCompareAndSwap = compareAndSwap exactCoordinate
      }
 where
  observe exactCoordinate coordinate =
    if coordinate == exactCoordinate
      then observeRetainedSesLease capability
      else pure (ModelBCorrupt coordinateRefusal)
  compareAndSwap exactCoordinate request = case request of
    ModelBInitialize coordinate projection
      | coordinate == exactCoordinate ->
          initializeRetainedSesLease capability projection
      | otherwise -> pure (ModelBCasRefusedCorrupt coordinateRefusal)
    ModelBReplace coordinate version projection
      | coordinate == exactCoordinate ->
          replaceRetainedSesLease capability version projection
      | otherwise -> pure (ModelBCasRefusedCorrupt coordinateRefusal)
    ModelBInitializeGuarded {} ->
      pure (ModelBCasRefusedCorrupt guardedRefusal)
    ModelBReplaceGuarded {} ->
      pure (ModelBCasRefusedCorrupt guardedRefusal)
  coordinateRefusal =
    "closed retained SES lease capability refused a non-registered coordinate"
  guardedRefusal =
    "closed retained SES lease capability does not expose guarded generic CAS"

decodeObservation
  :: LeasePolicy
  -> LeaseKey
  -> RetainedSesLeaseWireObservation
  -> ModelBObservation LeaseProjection
decodeObservation policy expectedKey observation = case observation of
  RetainedSesLeaseMissing -> ModelBMissing
  RetainedSesLeaseObserved rawVersion bytes ->
    case (mkModelBObjectVersion rawVersion, decodeProjection policy expectedKey bytes) of
      (Left err, _) -> ModelBCorrupt (Text.pack (show err))
      (_, Left detail) -> ModelBCorrupt detail
      (Right version, Right projection) -> ModelBObserved version projection
  RetainedSesLeaseCorrupt detail -> ModelBCorrupt detail
  RetainedSesLeaseEndpointUnready detail -> ModelBEndpointUnready detail
  RetainedSesLeaseUnobservable detail -> ModelBUnobservable detail

decodeCasResult
  :: LeasePolicy
  -> LeaseKey
  -> RetainedSesLeaseWireCasResult
  -> ModelBCasResult LeaseProjection
decodeCasResult policy expectedKey result = case result of
  RetainedSesLeaseApplied rawVersion bytes ->
    case (mkModelBObjectVersion rawVersion, decodeProjection policy expectedKey bytes) of
      (Left err, _) -> ModelBCasRefusedCorrupt (Text.pack (show err))
      (_, Left detail) -> ModelBCasRefusedCorrupt detail
      (Right version, Right projection) -> ModelBCasApplied version projection
  RetainedSesLeaseConflict observation ->
    ModelBCasConflict (decodeObservation policy expectedKey observation)
  RetainedSesLeaseCasRefusedCorrupt detail -> ModelBCasRefusedCorrupt detail
  RetainedSesLeaseCasEndpointUnready detail -> ModelBCasEndpointUnready detail
  RetainedSesLeaseCasUnobservable detail -> ModelBCasUnobservable detail

decodeProjection
  :: LeasePolicy
  -> LeaseKey
  -> ByteString
  -> Either Text LeaseProjection
decodeProjection policy expectedKey bytes = do
  projection <- first (Text.pack . show) (decodeLeaseProjection policy bytes)
  case projectionGrant projection of
    Just grant
      | leaseGrantKey grant == expectedKey -> Right projection
    _ -> Left "Lifecycle Authority retained-lease response key mismatch"

projectionGrant :: LeaseProjection -> Maybe LeaseGrant
projectionGrant projection =
  case leaseProjectionActiveGrant projection of
    Just grant -> Just grant
    Nothing -> leaseProjectionReleasedPredecessor projection

responseToken :: RetainedSesLeaseResponse -> Text
responseToken response = case response of
  RetainedSesLeaseObservation _ -> "observation"
  RetainedSesLeaseCas _ -> "cas"
  RetainedSesLeaseBadRequest detail -> "bad-request:" <> detail
  RetainedSesLeaseProjectionRefused detail -> "projection-refused:" <> detail
  RetainedSesLeaseUnavailable detail -> "unavailable:" <> detail
