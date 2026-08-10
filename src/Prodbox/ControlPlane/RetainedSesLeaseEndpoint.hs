{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed retained-lease protocol owned by the Lifecycle Authority.
--
-- The request vocabulary deliberately has no logical object name, Model-B
-- coordinate, authority endpoint, account, or region selector.  Startup binds
-- the handler to one exact discovered @aws-ses@ lease key and derives the
-- retained coordinate locally.  Projection bytes are decoded and checked
-- against that key before any CAS reaches the retained store.
module Prodbox.ControlPlane.RetainedSesLeaseEndpoint
  ( RetainedSesLeaseRequest (..)
  , RetainedSesLeaseWireObservation (..)
  , RetainedSesLeaseWireCasResult (..)
  , RetainedSesLeaseResponse (..)
  , RetainedSesLeaseHandler
  , retainedSesLeaseModelBCodec
  , mkRetainedSesLeaseHandler
  , resolvingRetainedSesLeaseHandler
  , runRetainedSesLeaseHandler
  , retainedSesLeaseResponseHttpStatus
  , retainedSesLeaseResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
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

-- | The complete externally admissible request vocabulary.  In particular,
-- there is no generic object-store operation and no caller-selected name.
data RetainedSesLeaseRequest
  = ObserveRetainedSesLease
  | InitializeRetainedSesLease !ByteString
  | ReplaceRetainedSesLease !Text !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedSesLeaseWireObservation
  = RetainedSesLeaseMissing
  | RetainedSesLeaseObserved !Text !ByteString
  | RetainedSesLeaseCorrupt !Text
  | RetainedSesLeaseEndpointUnready !Text
  | RetainedSesLeaseUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedSesLeaseWireCasResult
  = RetainedSesLeaseApplied !Text !ByteString
  | RetainedSesLeaseConflict !RetainedSesLeaseWireObservation
  | RetainedSesLeaseCasRefusedCorrupt !Text
  | RetainedSesLeaseCasEndpointUnready !Text
  | RetainedSesLeaseCasUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedSesLeaseResponse
  = RetainedSesLeaseObservation !RetainedSesLeaseWireObservation
  | RetainedSesLeaseCas !RetainedSesLeaseWireCasResult
  | RetainedSesLeaseBadRequest !Text
  | RetainedSesLeaseProjectionRefused !Text
  | RetainedSesLeaseUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedSesLeaseBinding m = RetainedSesLeaseBinding
  { retainedLeaseMaximumRequestBytes :: !Int
  , retainedLeasePolicy :: !LeasePolicy
  , retainedLeaseKey :: !LeaseKey
  , retainedLeaseAdapter
      :: !(ModelBCasAdapter 'ClusterRetained m LeaseProjection)
  , retainedLeaseCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  }

newtype RetainedSesLeaseHandler m = RetainedSesLeaseHandler
  { runRetainedSesLeaseHandler
      :: LazyByteString.ByteString
      -> m RetainedSesLeaseResponse
  }

retainedSesLeaseModelBCodec :: LeasePolicy -> ModelBCodec LeaseProjection
retainedSesLeaseModelBCodec policy =
  ModelBCodec
    { encodeModelBValue = Right . encodeLeaseProjection
    , decodeModelBValue = first show . decodeLeaseProjection policy
    }

-- | Bind the route to the one exact retained SES lease coordinate.  The
-- coordinate is derived here and cannot be supplied in a request.
mkRetainedSesLeaseHandler
  :: (Monad m)
  => Int
  -> LeasePolicy
  -> LongLivedCheckpointAuthority
  -> LeaseKey
  -> ModelBCasAdapter 'ClusterRetained m LeaseProjection
  -> Either AuthorityCoordinateError (RetainedSesLeaseHandler m)
mkRetainedSesLeaseHandler maximumBytes policy authority key adapter = do
  coordinate <- leaseObjectCoordinate authority key
  let binding =
        RetainedSesLeaseBinding
          { retainedLeaseMaximumRequestBytes = maximumBytes
          , retainedLeasePolicy = policy
          , retainedLeaseKey = key
          , retainedLeaseAdapter = adapter
          , retainedLeaseCoordinate = coordinate
          }
  pure
    ( RetainedSesLeaseHandler
        (serveRetainedSesLease binding)
    )

-- | Resolve the sealed exact binding per request.  The registration may be
-- committed after the Authority process starts; absence/corruption remains an
-- explicit unavailable response and never manufactures a default lease key.
resolvingRetainedSesLeaseHandler
  :: (Monad m)
  => m (Either Text (RetainedSesLeaseHandler m))
  -> RetainedSesLeaseHandler m
resolvingRetainedSesLeaseHandler resolve =
  RetainedSesLeaseHandler $ \body -> do
    resolved <- resolve
    case resolved of
      Left detail -> pure (RetainedSesLeaseUnavailable detail)
      Right handler -> runRetainedSesLeaseHandler handler body

serveRetainedSesLease
  :: (Monad m)
  => RetainedSesLeaseBinding m
  -> LazyByteString.ByteString
  -> m RetainedSesLeaseResponse
serveRetainedSesLease binding body =
  case decodeControlPlaneRequest (retainedLeaseMaximumRequestBytes binding) body of
    Left err -> pure (badRequest err)
    Right request -> case request of
      ObserveRetainedSesLease ->
        RetainedSesLeaseObservation . encodeObservation
          <$> modelBObserve
            (retainedLeaseAdapter binding)
            (retainedLeaseCoordinate binding)
      InitializeRetainedSesLease bytes ->
        applyProjection binding Nothing bytes
      ReplaceRetainedSesLease rawVersion bytes ->
        case mkModelBObjectVersion rawVersion of
          Left err -> pure (RetainedSesLeaseProjectionRefused (Text.pack (show err)))
          Right version -> applyProjection binding (Just version) bytes

applyProjection
  :: (Monad m)
  => RetainedSesLeaseBinding m
  -> Maybe ModelBObjectVersion
  -> ByteString
  -> m RetainedSesLeaseResponse
applyProjection binding expectedVersion bytes =
  case decodeLeaseProjection (retainedLeasePolicy binding) bytes of
    Left err -> pure (RetainedSesLeaseProjectionRefused (Text.pack (show err)))
    Right projection ->
      case validateProjectionKey (retainedLeaseKey binding) projection of
        Left detail -> pure (RetainedSesLeaseProjectionRefused detail)
        Right () -> do
          result <-
            modelBCompareAndSwap
              (retainedLeaseAdapter binding)
              ( case expectedVersion of
                  Nothing ->
                    ModelBInitialize
                      (retainedLeaseCoordinate binding)
                      projection
                  Just version ->
                    ModelBReplace
                      (retainedLeaseCoordinate binding)
                      version
                      projection
              )
          pure (RetainedSesLeaseCas (encodeCasResult result))

validateProjectionKey :: LeaseKey -> LeaseProjection -> Either Text ()
validateProjectionKey expected projection =
  case projectionGrant projection of
    Nothing -> Left "retained SES lease projection contains no grant"
    Just grant
      | leaseGrantKey grant == expected -> Right ()
      | otherwise ->
          Left "retained SES lease projection does not match the registered lease key"

projectionGrant :: LeaseProjection -> Maybe LeaseGrant
projectionGrant projection =
  case leaseProjectionActiveGrant projection of
    Just grant -> Just grant
    Nothing -> leaseProjectionReleasedPredecessor projection

encodeObservation
  :: ModelBObservation LeaseProjection
  -> RetainedSesLeaseWireObservation
encodeObservation observation = case observation of
  ModelBMissing -> RetainedSesLeaseMissing
  ModelBObserved version projection ->
    RetainedSesLeaseObserved
      (modelBObjectVersionText version)
      (encodeLeaseProjection projection)
  ModelBCorrupt detail -> RetainedSesLeaseCorrupt detail
  ModelBEndpointUnready detail -> RetainedSesLeaseEndpointUnready detail
  ModelBUnobservable detail -> RetainedSesLeaseUnobservable detail

encodeCasResult
  :: ModelBCasResult LeaseProjection
  -> RetainedSesLeaseWireCasResult
encodeCasResult result = case result of
  ModelBCasApplied version projection ->
    RetainedSesLeaseApplied
      (modelBObjectVersionText version)
      (encodeLeaseProjection projection)
  ModelBCasConflict observation ->
    RetainedSesLeaseConflict (encodeObservation observation)
  ModelBCasRefusedCorrupt detail -> RetainedSesLeaseCasRefusedCorrupt detail
  ModelBCasEndpointUnready detail -> RetainedSesLeaseCasEndpointUnready detail
  ModelBCasUnobservable detail -> RetainedSesLeaseCasUnobservable detail

badRequest :: ControlPlaneRequestCodecError -> RetainedSesLeaseResponse
badRequest = RetainedSesLeaseBadRequest . controlPlaneRequestCodecToken

retainedSesLeaseResponseHttpStatus :: RetainedSesLeaseResponse -> ReplyStatus
retainedSesLeaseResponseHttpStatus response = case response of
  RetainedSesLeaseObservation _ -> ReplyOk
  RetainedSesLeaseCas _ -> ReplyOk
  RetainedSesLeaseBadRequest _ -> ReplyBadRequest
  RetainedSesLeaseProjectionRefused _ -> ReplyBadRequest
  RetainedSesLeaseUnavailable _ -> ReplyServiceUnavailable

retainedSesLeaseResponseBody :: RetainedSesLeaseResponse -> ByteString
retainedSesLeaseResponseBody =
  LazyByteString.toStrict . encodeControlPlaneResponse
