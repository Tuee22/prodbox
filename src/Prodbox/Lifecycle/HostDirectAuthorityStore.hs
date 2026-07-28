{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RankNTypes #-}

-- | Sprint 4.51 Increment B (Stage B): the host-direct @'ClusterRetained@ Model-B
-- CAS adapter.
--
-- This is the Lifecycle Authority primary retained-MinIO namespace reached
-- host-direct — the same sealed objects the in-cluster gateway daemon serves,
-- but read/written in-process by the host CLI without the gateway HTTP hop. It
-- delegates to the shared 'modelBCasAdapterOverTransport' over a transport built
-- from the Stage-A 'Prodbox.Lifecycle.AuthorityObjectCore'-backed host-direct
-- primitives, so its sealed envelopes are byte-identical to the daemon's BY
-- CONSTRUCTION (both bottom out in the same @getLogicalVersioned@ /
-- @putLogicalIfAbsent@ / @putLogicalIfVersion@ under 'authorityLogicalObject').
--
-- The adapter is fixed to @'ClusterRetained@: a @'ChartLifetime@ (per-run /
-- chart-scoped) object can never be routed through the retained-authority
-- host-direct store, and vice-versa — a compile-time type error.
module Prodbox.Lifecycle.HostDirectAuthorityStore
  ( hostDirectModelBCasAdapter
  , materialHostDirectModelBCasAdapter
  , repoHostDirectModelBCasAdapter
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasResult (ModelBCasUnobservable)
  , ModelBCodec
  , ModelBObservation (ModelBUnobservable)
  )
import Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  )
import Prodbox.Lifecycle.StoreLifetime (StoreLifetime (ClusterRetained))
import Prodbox.Pulumi.HostDirectObjectStore
  ( HostDirectPulumiHandle
  , HostDirectPulumiMaterial
  , hostDirectCompareAndSwapAuthorityObject
  , hostDirectReadAuthorityObject
  , resolveHostDirectPulumiMaterial
  , withHostDirectPulumiPortForward
  )

-- | The retained-authority host-direct Model-B CAS adapter. It reaches the same
-- sealed objects as 'Prodbox.Lifecycle.CheckpointAuthorityStore.gatewayModelBCasAdapter'
-- through the in-process 'Prodbox.Lifecycle.AuthorityObjectCore' seam, and is
-- typed @'ClusterRetained@ so only retained control-plane coordinates may flow
-- through it.
hostDirectModelBCasAdapter
  :: HostDirectPulumiHandle
  -> LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter 'ClusterRetained IO value
hostDirectModelBCasAdapter handle authority codec =
  modelBCasAdapterOverTransport authority (hostDirectTransport handle) codec

-- | Production retained-store adapter for host commands. Each individual CAS
-- operation resolves the retained material and owns a short MinIO
-- port-forward window. No lease or provider operation can accidentally retain
-- that transport for its full (potentially seventy-minute) duration.
repoHostDirectModelBCasAdapter
  :: FilePath
  -> LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter 'ClusterRetained IO value
repoHostDirectModelBCasAdapter repoRoot authority codec =
  windowedHostDirectModelBCasAdapter
    (withRepoHostDirect repoRoot)
    authority
    codec

materialHostDirectModelBCasAdapter
  :: HostDirectPulumiMaterial
  -> LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter 'ClusterRetained IO value
materialHostDirectModelBCasAdapter material =
  windowedHostDirectModelBCasAdapter
    (fmap (first Text.pack) . withHostDirectPulumiPortForward material)

windowedHostDirectModelBCasAdapter
  :: (forall a. (HostDirectPulumiHandle -> IO a) -> IO (Either Text a))
  -> LongLivedCheckpointAuthority
  -> ModelBCodec value
  -> ModelBCasAdapter 'ClusterRetained IO value
windowedHostDirectModelBCasAdapter withWindow authority codec =
  ModelBCasAdapter
    { modelBObserve = \coordinate -> do
        result <-
          withWindow $ \handle ->
            modelBObserve (hostDirectModelBCasAdapter handle authority codec) coordinate
        pure (either ModelBUnobservable id result)
    , modelBCompareAndSwap = \request -> do
        result <-
          withWindow $ \handle ->
            modelBCompareAndSwap (hostDirectModelBCasAdapter handle authority codec) request
        pure (either ModelBCasUnobservable id result)
    }

withRepoHostDirect :: FilePath -> (HostDirectPulumiHandle -> IO a) -> IO (Either Text a)
withRepoHostDirect repoRoot action = do
  materialResult <- resolveHostDirectPulumiMaterial repoRoot
  case materialResult of
    Left err -> pure (Left (Text.pack err))
    Right material -> first Text.pack <$> withHostDirectPulumiPortForward material action

-- | A 'ModelBTransport' over the Stage-A host-direct authority-object primitives.
-- Their @Either String@ failures are normalised to 'Text' so the shared adapter
-- maps them to 'ModelBUnobservable' / 'ModelBCasUnobservable' exactly as the
-- gateway transport maps its rendered gateway errors.
hostDirectTransport :: HostDirectPulumiHandle -> ModelBTransport
hostDirectTransport handle =
  ModelBTransport
    { transportObserveObject = \logicalName ->
        first Text.pack <$> hostDirectReadAuthorityObject handle logicalName
    , transportCasObject = \request ->
        first Text.pack <$> hostDirectCompareAndSwapAuthorityObject handle request
    }
