{-# LANGUAGE OverloadedStrings #-}

-- | Runtime authentication consumes the same fenced birth records as admission.
-- Pending recovery can authenticate; it cannot read the ordinary admission repo.
module Prodbox.ControlPlane.RpcAdmissionBirthRuntime
  ( rpcBirthRuntimeRegistry
  , rpcBirthRuntimeTrust
  , observeRpcBirthRuntimeRegistry
  , resolveRpcBirthRuntimeSigner
  , RpcBirthRecoveryAuthentication
  , rpcBirthRecoveryAggregate
  , resolveRpcBirthRecoveryAuthentication
  , observeRpcBirthRecoveryTrust
  , resolveRpcBirthRecoverySigner
  )
where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( RouteTrustRegistry
  , routeTrustRegistryMaximumKeys
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RegisteredRpcSigning
import Prodbox.ControlPlane.RequestAuthentication
  ( CallerPrincipal (CallerService)
  , RequestSigningCapability
  , mkRequestSigningCapability
  , requestSigningCapabilityGeneration
  , requestSigningCapabilityPrincipal
  , requestSigningCapabilityPublicKeyBytes
  , signCanonicalBytesWithRequestCapability
  )
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
  ( rpcBirthAuthenticationAdmission
  , rpcBirthAuthenticationRegistry
  )
import Prodbox.ControlPlane.RpcAdmissionBirthNative
  ( RpcBirthNativeBackend
  , observeHomeRpcSeed
  , observeRpcBirthNativeRecords
  )
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , seedAuthorityRpcKeyRegistry
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBObservation (..))
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Vault.Session (VaultSession)

-- Current records retain public provenance through retirement. This snapshot
-- also carries the exact observed source while an already historical seedless
-- prefix is finished; neither mode can supply an absent or foreign record.
data RpcBirthRecoveryAuthentication
  = RpcBirthRecoveryAuthentication
      !RpcBirthDescriptor
      !RpcKeyRegistry
      !AuthorityAdmissionAggregate

rpcBirthRecoveryAggregate :: RpcBirthRecoveryAuthentication -> AuthorityAdmissionAggregate
rpcBirthRecoveryAggregate (RpcBirthRecoveryAuthentication _ _ aggregate) = aggregate

resolveRpcBirthRecoveryAuthentication
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> AuthorityScope
  -> VaultSession
  -> IO (Either RpcBirthError RpcBirthRecoveryAuthentication)
resolveRpcBirthRecoveryAuthentication backend mode scope session
  | not (rpcBirthServingModeRequiresRegistration mode) = pure (Left RpcBirthPublicationRequired)
  | otherwise = do
      (record, marker) <- observeRpcBirthNativeRecords backend
      let selected = do
            aggregate <-
              rpcBirthAuthenticationAdmission mode record marker
                >>= maybe (Left RpcBirthAdmissionMissing) Right
            descriptor <- case record of
              ModelBObserved _ value -> maybe (Left RpcBirthDescriptorInvalid) Right (rpcBirthDescriptor value)
              _ -> Left RpcBirthAdmissionMissing
            registry <- rpcBirthRuntimeRegistry mode record marker
            pure (aggregate, descriptor, registry)
      case selected of
        Left cause -> pure (Left cause)
        Right (aggregate, descriptor, registry) -> do
          observed <- case registry of
            Just value -> pure (rpcBirthOriginalHomeSeed value)
            Nothing -> observeHomeRpcSeed scope session
          pure $ do
            seed <- observed
            digest <- rpcBirthSeedDigest seed
            unless (digest == rpcBirthDescriptorSeedDigest descriptor) (Left RpcBirthSeedChanged)
            unless (rpcBirthDescriptorScope descriptor == scope) (Left RpcBirthScopeMismatch)
            case registry of
              Just _ -> Right ()
              Nothing -> do
                _ <- first (const RpcBirthSeedInvalid) (seedAuthorityRpcKeyRegistry scope seed aggregate)
                Right ()
            pure (RpcBirthRecoveryAuthentication descriptor seed aggregate)

observeRpcBirthRecoveryRegistry
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> RpcBirthRecoveryAuthentication
  -> IO (Either RpcBirthError RpcKeyRegistry)
observeRpcBirthRecoveryRegistry backend mode (RpcBirthRecoveryAuthentication expected original _) = do
  (record, marker) <- observeRpcBirthNativeRecords backend
  pure $ do
    unless (rpcBirthServingModeRequiresRegistration mode) (Left RpcBirthPublicationRequired)
    registry <- rpcBirthRuntimeRegistry mode record marker
    case record of
      ModelBObserved _ value ->
        unless (rpcBirthDescriptor value == Just expected) (Left RpcBirthMarkerMismatch)
      _ -> Left RpcBirthAdmissionMissing
    pure (maybe original id registry)

observeRpcBirthRecoveryTrust
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> Natural
  -> RpcBirthRecoveryAuthentication
  -> IO (Either Text RouteTrustRegistry)
observeRpcBirthRecoveryTrust backend mode maximumTrust authentication = do
  observed <- observeRpcBirthRecoveryRegistry backend mode authentication
  pure $ first (Text.pack . show) $ do
    registry <- observed
    first
      (const RpcBirthNativeCompatibilityMismatch)
      (registeredRpcRouteTrust LifecycleAuthorityRuntime maximumTrust registry)

resolveRpcBirthRecoverySigner
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> AuthorityScope
  -> VaultSession
  -> RpcBirthRecoveryAuthentication
  -> IO (Either Text (RequestSigningCapability IO))
resolveRpcBirthRecoverySigner backend mode scope session authentication = do
  observed <- observeRpcBirthRecoveryRegistry backend mode authentication
  case first (Text.pack . show) observed of
    Left cause -> pure (Left cause)
    Right registry -> resolveRuntimeRegistrySigner scope session observer registry
 where
  observer = RpcKeyRegistryObserver $ do
    observed <- observeRpcBirthRecoveryRegistry backend mode authentication
    pure (first (const RpcKeyBindingMissing) observed)

resolveRuntimeRegistrySigner
  :: AuthorityScope
  -> VaultSession
  -> RpcKeyRegistryObserver IO
  -> RpcKeyRegistry
  -> IO (Either Text (RequestSigningCapability IO))
resolveRuntimeRegistrySigner scope session observer registry =
  first renderRegisteredRpcSigningError
    <$> resolveActiveRegisteredRpcSigningCapability interpreter registry
 where
  ref = controlPlaneSigningKeyRefFor (CallerService LifecycleAuthorityRuntime)
  interpreter = vaultRegisteredRpcSigningInterpreter scope scope ref session observer

rpcBirthRuntimeRegistry
  :: RpcBirthServingMode
  -> ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError (Maybe RpcKeyRegistry)
rpcBirthRuntimeRegistry = rpcBirthAuthenticationRegistry

rpcBirthRuntimeTrust
  :: RpcBirthServingMode
  -> RouteTrustRegistry
  -> ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError RouteTrustRegistry
rpcBirthRuntimeTrust mode legacy record marker = do
  registry <- rpcBirthRuntimeRegistry mode record marker
  case registry of
    Nothing -> Right legacy
    Just registered ->
      first
        (const RpcBirthNativeCompatibilityMismatch)
        (registeredRpcRouteTrust LifecycleAuthorityRuntime (routeTrustRegistryMaximumKeys legacy) registered)

observeRpcBirthRuntimeRegistry
  :: RpcBirthNativeBackend -> RpcBirthServingMode -> IO (Either Text (Maybe RpcKeyRegistry))
observeRpcBirthRuntimeRegistry backend mode = do
  (record, marker) <- observeRpcBirthNativeRecords backend
  pure (first (Text.pack . show) (rpcBirthRuntimeRegistry mode record marker))

resolveRpcBirthRuntimeSigner
  :: RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> AuthorityScope
  -> VaultSession
  -> RequestSigningCapability IO
  -> IO (Either Text (RequestSigningCapability IO))
resolveRpcBirthRuntimeSigner backend mode scope session legacy = do
  observed <-
    if requestSigningCapabilityPrincipal legacy == CallerService LifecycleAuthorityRuntime
      then observeRpcBirthRuntimeRegistry backend mode
      else pure (Left "registered-rpc-signing/capability-invalid")
  case observed of
    Left cause -> pure (Left cause)
    Right Nothing ->
      pure $
        first (Text.pack . show) $
          mkRequestSigningCapability
            (requestSigningCapabilityPrincipal legacy)
            (requestSigningCapabilityGeneration legacy)
            (requestSigningCapabilityPublicKeyBytes legacy)
            legacySign
    Right (Just registry) -> resolveRuntimeRegistrySigner scope session observer registry
 where
  observer = RpcKeyRegistryObserver $ do
    result <- observeRpcBirthRuntimeRegistry backend mode
    pure $ case result of
      Right (Just registry) -> Right registry
      _ -> Left RpcKeyBindingMissing
  legacySign bytes = do
    before <- observeRpcBirthRuntimeRegistry backend mode
    case before of
      Right Nothing -> do
        signed <- first (Text.pack . show) <$> signCanonicalBytesWithRequestCapability legacy bytes
        after <- observeRpcBirthRuntimeRegistry backend mode
        pure $ do
          signature <- signed
          unless (after == Right Nothing) (Left "rpc-birth/legacy-signer-fenced")
          pure signature
      _ -> pure (Left "rpc-birth/legacy-signer-fenced")
