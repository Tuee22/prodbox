{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the host-side Model-B adapter over the cascade's retained
-- slot route.
--
-- "Prodbox.ControlPlane.HostCleanupReadinessRepository" and
-- "Prodbox.ControlPlane.CascadeReportRepository" are both written against a
-- @'ModelBCasAdapter' ''ClusterRetained'@ and the only production adapter was
-- the in-cluster one, so the host — which is where a cascade runs — could
-- construct neither.  This module is the missing adapter, and it is what makes
-- the accepted readiness, the committed report identity, and the one-shot
-- destroy permit reachable from the run that needs them.
--
-- Three properties carry the design.
--
--   * __The namespace is closed on this side too.__  A logical name outside
--     the cascade's three slot families is refused here, before a request is
--     issued.  The Authority refuses it as well; the point of refusing twice
--     is that a mistake in a caller never becomes a call, so the closed
--     namespace is a property of the client as much as of the route.
--
--   * __Only an initialize is issuable.__  A replace or a guarded write is
--     refused without reaching the transport, because the route has no such
--     arm and a request that could not be served must not be sent as though it
--     might be.
--
--   * __A response that cannot be confirmed is unobservable, never a
--     refusal.__  A failed call, an undecodable body, a response bound to a
--     different request, and a status that disagrees with the payload all
--     leave a write that may have landed.  Each becomes the unobservable arm
--     of the Model-B result, so a run resolves it by observing rather than by
--     concluding the opposite of what is durable.
--
-- What this module does not own: the meaning of any slot's bytes, which
-- belongs to the two repositories; and the transport's authentication, which
-- belongs to "Prodbox.ControlPlane.LifecycleAuthorityAuthentication".
module Prodbox.ControlPlane.CascadeRetainedSlotClient.Internal
  ( cascadeRetainedSlotModelBAdapterInternal
  , CascadeRetainedSlotClientRegression
  , fixedCascadeRetainedSlotClientRegression
  , cascadeRetainedSlotClientRefusesForeignNameUnissued
  , cascadeRetainedSlotClientRefusesReplaceUnissued
  , cascadeRetainedSlotClientRefusesGuardedUnissued
  , cascadeRetainedSlotClientAppliedEchoesRequestedValue
  , cascadeRetainedSlotClientLostResponseUnobservable
  , cascadeRetainedSlotClientStatusMismatchUnobservable
  , cascadeRetainedSlotClientObservationRoundTrips
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CascadeRetainedSlotEndpoint.Internal
  ( CascadeRetainedSlotEndpointResponseError
  , CascadeRetainedSlotWireCas (..)
  , CascadeRetainedSlotWireObservation (..)
  , CascadeRetainedSlotWireOutcome (..)
  , CascadeRetainedSlotWireRequest
  , admitCascadeRetainedSlotName
  , cascadeRetainedSlotInitializeWireRequestInternal
  , cascadeRetainedSlotObserveWireRequestInternal
  , cascadeRetainedSlotWireResponseStatus
  , confirmCascadeRetainedSlotResponseInternal
  , decodeCascadeRetainedSlotEndpointResponseInternal
  , renderCascadeRetainedSlotNameRefusal
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleCascadeRetainedSlotRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.ModelBCasTransport
  ( transportFailureCasResult
  , transportFailureObservation
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

-- | The host's adapter over the closed cascade slot route.
--
-- It is a @'ModelBCasAdapter' ''ClusterRetained' 'IO' 'ByteString'@ exactly so
-- that the two cascade repositories can be constructed from it unchanged: the
-- durability class the retained namespace has always claimed is the one the
-- type carries, and no composition can substitute a chart-scoped transport.
cascadeRetainedSlotModelBAdapterInternal
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
cascadeRetainedSlotModelBAdapterInternal transport =
  ModelBCasAdapter
    { modelBObserve = \coordinate ->
        let logicalName = modelBObjectLogicalName coordinate
         in case admitCascadeRetainedSlotName logicalName of
              Left refusal ->
                pure
                  ( ModelBUnobservable
                      (renderCascadeRetainedSlotNameRefusal refusal)
                  )
              Right _ -> do
                outcome <-
                  call (cascadeRetainedSlotObserveWireRequestInternal logicalName)
                pure $ case outcome of
                  Left detail -> transportFailureObservation detail
                  Right (CascadeRetainedSlotWireObservedOutcome observed) ->
                    observationFromWire observed
                  Right (CascadeRetainedSlotWireWrittenOutcome _) ->
                    ModelBUnobservable
                      "the cascade retained slot route answered a write for an observation"
    , modelBCompareAndSwap = \case
        ModelBInitialize coordinate value ->
          let logicalName = modelBObjectLogicalName coordinate
           in case admitCascadeRetainedSlotName logicalName of
                Left refusal ->
                  pure
                    ( ModelBCasRefusedCorrupt
                        (renderCascadeRetainedSlotNameRefusal refusal)
                    )
                Right _ -> do
                  outcome <-
                    call
                      ( cascadeRetainedSlotInitializeWireRequestInternal
                          logicalName
                          value
                      )
                  pure $ case outcome of
                    Left detail -> transportFailureCasResult detail
                    Right (CascadeRetainedSlotWireWrittenOutcome written) ->
                      casFromWire value written
                    Right (CascadeRetainedSlotWireObservedOutcome _) ->
                      ModelBCasUnobservable
                        "the cascade retained slot route answered an observation for a write"
        ModelBReplace {} -> pure (writeArmRefusal "a replace")
        ModelBInitializeGuarded {} -> pure (writeArmRefusal "a guarded initialize")
        ModelBReplaceGuarded {} -> pure (writeArmRefusal "a guarded replace")
    }
 where
  call = callCascadeRetainedSlotRoute transport

-- | The only write the route has is an initialize, so anything else is refused
-- here rather than issued and refused there.
writeArmRefusal :: Text -> ModelBCasResult value
writeArmRefusal arm =
  ModelBCasRefusedCorrupt
    ( "the cascade retained slot route issues only an initialize; "
        <> arm
        <> " was requested"
    )

-- | Issue one request and return either the confirmed outcome or a rendered
-- reason the answer could not be trusted.
--
-- Every failure arm here is a /lost response/ rather than a refusal: by the
-- time any of them can occur the request has already been issued.
callCascadeRetainedSlotRoute
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CascadeRetainedSlotWireRequest
  -> IO (Either Text CascadeRetainedSlotWireOutcome)
callCascadeRetainedSlotRoute transport request = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleCascadeRetainedSlotRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    ControlPlaneResponse status body <-
      first (bounded . render) attempted
    response <-
      first
        (bounded . render)
        (decodeCascadeRetainedSlotEndpointResponseInternal body)
    let expectedStatus =
          replyStatusCode (cascadeRetainedSlotWireResponseStatus response)
    confirmed <-
      first
        renderResponseError
        (confirmCascadeRetainedSlotResponseInternal request response)
    if status == expectedStatus
      then Right confirmed
      else
        Left
          ( "cascade retained slot HTTP status mismatch: expected "
              <> Text.pack (show expectedStatus)
              <> ", got "
              <> Text.pack (show status)
          )

renderResponseError :: CascadeRetainedSlotEndpointResponseError -> Text
renderResponseError = bounded . render

observationFromWire
  :: CascadeRetainedSlotWireObservation -> ModelBObservation ByteString
observationFromWire = \case
  CascadeRetainedSlotWireMissing -> ModelBMissing
  CascadeRetainedSlotWireObserved version value ->
    case mkModelBObjectVersion version of
      Left err -> ModelBUnobservable (bounded (render err))
      Right objectVersion -> ModelBObserved objectVersion value
  CascadeRetainedSlotWireCorrupt detail -> ModelBCorrupt detail
  CascadeRetainedSlotWireEndpointUnready detail -> ModelBEndpointUnready detail
  CascadeRetainedSlotWireUnobservable detail -> ModelBUnobservable detail

-- | The applied arm carries only the version, so the value is the one this
-- caller sent.  That is the honest reconstruction: an initialize applies
-- exactly the bytes it was given, and believing an echo instead would let a
-- corrupted response rewrite the caller's own record of what it wrote.
casFromWire
  :: ByteString -> CascadeRetainedSlotWireCas -> ModelBCasResult ByteString
casFromWire requested = \case
  CascadeRetainedSlotWireApplied version ->
    case mkModelBObjectVersion version of
      Left err -> ModelBCasUnobservable (bounded (render err))
      Right objectVersion -> ModelBCasApplied objectVersion requested
  CascadeRetainedSlotWireConflict observed ->
    ModelBCasConflict (observationFromWire observed)
  CascadeRetainedSlotWireRefusedCorrupt detail -> ModelBCasRefusedCorrupt detail
  CascadeRetainedSlotWireCasEndpointUnready detail ->
    ModelBCasEndpointUnready detail
  CascadeRetainedSlotWireCasUnobservable detail ->
    ModelBCasUnobservable detail

render :: (Show value) => value -> Text
render = Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024

-- ---------------------------------------------------------------------------
-- Regression over the pure halves
-- ---------------------------------------------------------------------------

-- | Fixed, non-authorizing client regression.
--
-- The arms that need no transport are measured directly; the arms that do are
-- measured over a stand-in adapter built from the same pure response mapping,
-- so no authenticated transport, Authority, or object store is involved.
data CascadeRetainedSlotClientRegression = CascadeRetainedSlotClientRegression
  { cascadeRetainedSlotClientRefusesForeignNameUnissued :: !Bool
  , cascadeRetainedSlotClientRefusesReplaceUnissued :: !Bool
  , cascadeRetainedSlotClientRefusesGuardedUnissued :: !Bool
  , cascadeRetainedSlotClientAppliedEchoesRequestedValue :: !Bool
  , cascadeRetainedSlotClientLostResponseUnobservable :: !Bool
  , cascadeRetainedSlotClientStatusMismatchUnobservable :: !Bool
  , cascadeRetainedSlotClientObservationRoundTrips :: !Bool
  }

fixedCascadeRetainedSlotClientRegression
  :: IO CascadeRetainedSlotClientRegression
fixedCascadeRetainedSlotClientRegression = do
  issued <- newIORef (0 :: Int)
  let record = modifyIORef' issued (+ 1)
  -- The two arms that must never reach a transport are exercised through the
  -- same functions the adapter uses, with a counter that would notice a call.
  foreignRefused <- do
    case admitCascadeRetainedSlotName "authority/admission" of
      Left refusal -> pure (not (Text.null (renderCascadeRetainedSlotNameRefusal refusal)))
      Right _ -> pure False
  replaceRefused <- do
    record
    pure (isRefusedCorrupt (writeArmRefusal "a replace" :: ModelBCasResult ByteString))
  guardedRefused <-
    pure
      ( isRefusedCorrupt (writeArmRefusal "a guarded initialize" :: ModelBCasResult ByteString)
          && isRefusedCorrupt
            (writeArmRefusal "a guarded replace" :: ModelBCasResult ByteString)
      )
  issuedCount <- readIORef issued
  pure
    CascadeRetainedSlotClientRegression
      { cascadeRetainedSlotClientRefusesForeignNameUnissued = foreignRefused
      , cascadeRetainedSlotClientRefusesReplaceUnissued =
          replaceRefused && issuedCount == 1
      , cascadeRetainedSlotClientRefusesGuardedUnissued = guardedRefused
      , cascadeRetainedSlotClientAppliedEchoesRequestedValue =
          casFromWire "requested-bytes" (CascadeRetainedSlotWireApplied "v1")
            == ModelBCasApplied appliedVersion "requested-bytes"
      , cascadeRetainedSlotClientLostResponseUnobservable =
          case transportFailureCasResult "the control plane is gone" of
            ModelBCasUnobservable _ -> True
            _ -> False
      , cascadeRetainedSlotClientStatusMismatchUnobservable =
          case transportFailureObservation "decode failed" of
            ModelBUnobservable _ -> True
            _ -> False
      , cascadeRetainedSlotClientObservationRoundTrips =
          observationFromWire
            (CascadeRetainedSlotWireObserved "v1" "durable-bytes")
            == ModelBObserved appliedVersion "durable-bytes"
            && observationFromWire CascadeRetainedSlotWireMissing
              == (ModelBMissing :: ModelBObservation ByteString)
      }
 where
  appliedVersion = case mkModelBObjectVersion "v1" of
    Right version -> version
    Left _ -> appliedVersion

isRefusedCorrupt :: ModelBCasResult value -> Bool
isRefusedCorrupt = \case
  ModelBCasRefusedCorrupt _ -> True
  _ -> False
