{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Native Vault/public-key and retained Model-B boundaries for RPC birth.
-- No key creation, private-key export or native-counter reconstruction occurs.
module Prodbox.ControlPlane.RpcAdmissionBirthNative
  ( RpcBirthNativeBackend
  , inClusterRpcBirthBackend
  , inClusterPinnedRpcBirthBackend
  , modelBRpcBirthBackend
  , rpcBirthNativeInterpreter
  , rpcBirthNativeAdmissionRepository
  , rpcBirthNativeAuthenticationAdmission
  , observeRpcBirthNativeRecords
  , observeCompatibleHomeRpcSeed
  , observeHomeRpcSeed
  , rpcBirthSystemTime
  )
where

import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( RouteTrustRegistry
  , routeTrustRegistryKeysFor
  , routeTrustRegistryMaximumKeys
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyInventory
  , controlPlaneSigningKeyName
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  , authorityAdmissionMaximumEncodedBytes
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , inClusterAuthorityModelBCasAdapter
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( trustedRequestCallerPrincipal
  , trustedRequestGeneration
  , trustedRequestPublicKeyBytes
  )
import Prodbox.ControlPlane.Route (routesForRole)
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.Lifecycle.Authority.Admission (AuthorityAdmissionAggregate)
import Prodbox.Lifecycle.Authority.ClientRegistry (RegisteredClientTable)
import Prodbox.Lifecycle.CheckpointAuthority
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Vault.Client
  ( TransitSigningKeyInfo (..)
  , vaultReadClusterIncarnation
  , vaultReadTransitSigningKeyBounded
  )
import Prodbox.Vault.Session (VaultSession, sessionAddress, withSessionToken)
import System.Timeout (timeout)

-- Fixed coordinates are constructed by the owning Authority, never a request.
data RpcBirthNativeBackend
  = RpcBirthNativeBackend
      !(ModelBCasAdapter 'ClusterRetained IO RpcBirthRecord)
      !(ModelBObjectCoordinate 'ClusterRetained)
      !(ModelBCasAdapter 'ClusterRetained IO RpcBirthMarker)
      !(ModelBObjectCoordinate 'ClusterRetained)
      !(IO (Either RpcBirthError RpcKeyRegistry))

inClusterRpcBirthBackend
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> AuthorityScope
  -> Natural
  -> Natural
  -> RegisteredClientTable
  -> VaultSession
  -> RouteTrustRegistry
  -> Either RpcBirthError RpcBirthNativeBackend
inClusterRpcBirthBackend store authority scope live retained legacyClients session trust =
  inClusterRpcBirthBackendWithCodec
    store
    authority
    scope
    (rpcBirthRecordCodec authorityAdmissionMaximumEncodedBytes live retained scope legacyClients)
    (const (observeCompatibleHomeRpcSeed scope session trust))

inClusterPinnedRpcBirthBackend
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> AuthorityScope
  -> Natural
  -> Natural
  -> Natural
  -> RpcBirthServingMode
  -> VaultSession
  -> Either RpcBirthError RpcBirthNativeBackend
inClusterPinnedRpcBirthBackend store authority scope live retained maximumTrust mode session = do
  codec <- rpcBirthPinnedRecordCodec authorityAdmissionMaximumEncodedBytes live retained scope mode
  inClusterRpcBirthBackendWithCodec store authority scope codec readSeed
 where
  readSeed backend = do
    (record, marker) <- observeRpcBirthNativeRecords backend
    let expected = do
          _ <- rpcBirthAuthenticationAdmission mode record marker
          seed <- case record of
            ModelBObserved _ value -> maybe (Left RpcBirthWrongPhase) Right (rpcBirthCandidate value)
            _ -> Left RpcBirthAdmissionMissing
          first
            (const RpcBirthNativeCompatibilityMismatch)
            (registeredRpcRouteTrust LifecycleAuthorityRuntime maximumTrust seed)
    case expected of
      Left cause -> pure (Left cause)
      Right trust -> observeCompatibleHomeRpcSeed scope session trust

inClusterRpcBirthBackendWithCodec
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> AuthorityScope
  -> ModelBCodec RpcBirthRecord
  -> (RpcBirthNativeBackend -> IO (Either RpcBirthError RpcKeyRegistry))
  -> Either RpcBirthError RpcBirthNativeBackend
inClusterRpcBirthBackendWithCodec store authority scope codec readSeed = do
  unless
    (checkpointAuthorityClusterId authority == authorityScopeText scope)
    (Left RpcBirthScopeMismatch)
  primary <-
    first (const RpcBirthStateInvalid) (mkClusterRetainedCoordinate authority "authority/admission")
  marker <-
    first
      (const RpcBirthStateInvalid)
      (mkClusterRetainedCoordinate authority "authority/rpc-registration-birth")
  let backend =
        modelBRpcBirthBackend
          ( inClusterAuthorityModelBCasAdapter
              store
              authority
              codec
          )
          primary
          (inClusterAuthorityModelBCasAdapter store authority (rpcBirthMarkerCodec scope))
          marker
          (readSeed backend)
  pure backend

modelBRpcBirthBackend
  :: ModelBCasAdapter 'ClusterRetained IO RpcBirthRecord
  -> ModelBObjectCoordinate 'ClusterRetained
  -> ModelBCasAdapter 'ClusterRetained IO RpcBirthMarker
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (Either RpcBirthError RpcKeyRegistry)
  -> RpcBirthNativeBackend
modelBRpcBirthBackend = RpcBirthNativeBackend

rpcBirthSystemTime :: IO AuthorityTime
rpcBirthSystemTime = do
  now <- getCurrentTime
  pure
    ( authorityTimeFromMicros
        (fromInteger (max 0 (floor (utcTimeToPOSIXSeconds now * 1000000) :: Integer)))
    )

-- The concrete native clock is a local UTC read, not a remote provider. Every
-- native effect, session renewal and forced codec result shares the supplied
-- absolute deadline; an interrupted CAS remains unresolved until readback.
rpcBirthNativeInterpreter :: RpcBirthNativeBackend -> RpcBirthInterpreter IO
rpcBirthNativeInterpreter backend = RpcBirthInterpreter run
 where
  run :: AuthorityTime -> RpcBirthProgram result -> IO (Either RpcBirthError result)
  run deadline program = do
    now <- rpcBirthSystemTime
    if now >= deadline
      then pure (Left RpcBirthDeadlineReached)
      else do
        let remaining = authorityTimeMicros deadline - authorityTimeMicros now
            limit = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
        attempted <- timeout limit $ do
          result <- dispatch program
          _ <- evaluate result
          closing <- rpcBirthSystemTime
          pure (if closing >= deadline then Left RpcBirthDeadlineReached else result)
        pure (maybe (Left RpcBirthEffectTimedOut) id attempted)
  dispatch :: RpcBirthProgram result -> IO (Either RpcBirthError result)
  dispatch program = case backend of
    RpcBirthNativeBackend primary primaryCoordinate marker markerCoordinate readSeed -> case program of
      ReadRpcBirthTime -> Right <$> rpcBirthSystemTime
      ReadRpcBirthRecord -> Right <$> modelBObserve primary primaryCoordinate
      ReadRpcBirthMarker -> Right <$> modelBObserve marker markerCoordinate
      ReadRpcBirthHomeSeed -> readSeed
      CasRpcBirthRecord expected value -> Right <$> modelBCompareAndSwap primary (ModelBReplace primaryCoordinate expected value)
      CasRpcBirthMarker expected value ->
        Right
          <$> modelBCompareAndSwap
            marker
            ( case expected of
                Nothing -> ModelBInitialize markerCoordinate value
                Just version -> ModelBReplace markerCoordinate version value
            )

observeRpcBirthNativeRecords
  :: RpcBirthNativeBackend
  -> IO (ModelBObservation RpcBirthRecord, ModelBObservation RpcBirthMarker)
observeRpcBirthNativeRecords (RpcBirthNativeBackend primary primaryCoordinate marker markerCoordinate _) = do
  record <- modelBObserve primary primaryCoordinate
  anchor <- modelBObserve marker markerCoordinate
  confirmation <- modelBObserve primary primaryCoordinate
  pure (confirmRpcBirthPrimaryObservation record confirmation, anchor)

rpcBirthNativeAuthenticationAdmission
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> IO (Either Text (Maybe AuthorityAdmissionAggregate))
rpcBirthNativeAuthenticationAdmission backend mode = do
  (record, marker) <- observeRpcBirthNativeRecords backend
  pure (first (Text.pack . show) (rpcBirthAuthenticationAdmission mode record marker))

rpcBirthNativeAdmissionRepository
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO (Maybe ModelBObjectVersion)
rpcBirthNativeAdmissionRepository backend@(RpcBirthNativeBackend primary coordinate _ _ _) mode legacyInitializer =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        (record, marker) <- observeRpcBirthNativeRecords backend
        pure $ do
          selected <- first (Text.pack . show) (rpcBirthNormalAdmission mode record marker)
          pure $ case selected of
            Nothing -> AuthorityAdmissionSnapshot Nothing legacyInitializer
            Just (version, aggregate) -> AuthorityAdmissionSnapshot (Just version) aggregate
    , compareAndSwapAuthorityAdmission = \expected aggregate -> do
        (record, marker) <- observeRpcBirthNativeRecords backend
        case rpcBirthNormalAdmission mode record marker of
          Left cause -> pure (Left (Text.pack (show cause)))
          Right selected
            | fmap fst selected /= expected -> pure (Left "RpcBirthWriteUnconfirmed")
            | otherwise -> case record of
                ModelBMissing -> case rpcBirthLegacy aggregate of
                  Left cause -> pure (Left (Text.pack (show cause)))
                  Right next -> result <$> modelBCompareAndSwap primary (ModelBInitialize coordinate next)
                ModelBObserved version previous -> case replaceRpcBirthAdmission previous aggregate of
                  Left cause -> pure (Left (Text.pack (show cause)))
                  Right next -> result <$> modelBCompareAndSwap primary (ModelBReplace coordinate version next)
                ModelBCorrupt _ -> pure (Left "RpcBirthStateInvalid")
                ModelBEndpointUnready _ -> pure (Left "RpcBirthObservationUnavailable")
                ModelBUnobservable _ -> pure (Left "RpcBirthObservationUnavailable")
    }
 where
  result outcome = case outcome of
    ModelBCasApplied _ _ -> Right ()
    ModelBCasConflict _ -> Left "RpcBirthWriteUnconfirmed"
    ModelBCasRefusedCorrupt _ -> Left "RpcBirthStateInvalid"
    ModelBCasEndpointUnready _ -> Left "RpcBirthObservationUnavailable"
    ModelBCasUnobservable _ -> Left "RpcBirthWriteUnconfirmed"

-- This is compatibility of existing home grants. Independent foreign source
-- custody/non-cloning is not established by a Vault UUID or public key alone.
observeCompatibleHomeRpcSeed
  :: AuthorityScope
  -> VaultSession
  -> RouteTrustRegistry
  -> IO (Either RpcBirthError RpcKeyRegistry)
observeCompatibleHomeRpcSeed scope session trusted = do
  observed <- observeHomeRpcSeed scope session
  pure $ do
    seed <- observed
    projected <-
      first
        (const RpcBirthNativeCompatibilityMismatch)
        (registeredRpcRouteTrust LifecycleAuthorityRuntime (routeTrustRegistryMaximumKeys trusted) seed)
    unless
      (all (sameRoute projected) (routesForRole LifecycleAuthorityRuntime))
      (Left RpcBirthNativeCompatibilityMismatch)
    pure seed
 where
  sameRoute projected route = entries projected route == entries trusted route
  entries registry route =
    Map.fromList
      [ ( (trustedRequestCallerPrincipal key, trustedRequestGeneration key)
        , trustedRequestPublicKeyBytes key
        )
      | key <- routeTrustRegistryKeysFor route registry
      ]

observeHomeRpcSeed :: AuthorityScope -> VaultSession -> IO (Either RpcBirthError RpcKeyRegistry)
observeHomeRpcSeed scope session = do
  firstSnapshot <- snapshot
  secondSnapshot <- snapshot
  pure $ do
    left <- firstSnapshot
    right <- secondSnapshot
    unless (left == right) (Left RpcBirthNativeSourceChanged)
    pure left
 where
  snapshot = do
    incarnation <- withSessionToken session $ \token -> vaultReadClusterIncarnation (sessionAddress session) token
    case first (const RpcBirthNativeSourceUnavailable) incarnation
      >>= first (const RpcBirthNativeSourceUnavailable) . mkRpcVaultIncarnation of
      Left cause -> pure (Left cause)
      Right vault -> do
        public <- traverse (observePublic vault) controlPlaneSigningKeyInventory
        pure $ do
          keys <- sequence public
          first (const RpcBirthSeedInvalid) (seedLegacyRpcKeyRegistry scope keys)
  observePublic vault ref = do
    observed <- withSessionToken session $ \token ->
      vaultReadTransitSigningKeyBounded
        (sessionAddress session)
        token
        (controlPlaneSigningKeyName ref)
    pure $ do
      key <- first (const RpcBirthNativeSourceUnavailable) observed
      unless
        (transitSigningKeyName key == controlPlaneSigningKeyName ref)
        (Left RpcBirthNativeCompatibilityMismatch)
      first
        (const RpcBirthSeedInvalid)
        ( mkRpcObservedKey
            (mkRpcKeyOrigin scope vault ref)
            (transitSigningKeyVersion key)
            (transitSigningPublicKey key)
        )
