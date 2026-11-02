{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Logical wire identity and native signing version are separate bindings.
-- Each signature re-observes the retained registration and its native source.
module Prodbox.ControlPlane.RegisteredRpcSigning
  ( RpcKeyRegistryObserver (..)
  , NativeRpcSigningProgram (..)
  , NativeRpcSigningInterpreter (..)
  , vaultNativeRpcSigningInterpreter
  , RegisteredRpcSigningProgram (..)
  , RegisteredRpcSigningInterpreter (..)
  , RegisteredRpcSigningError (..)
  , vaultRegisteredRpcSigningInterpreter
  , resolveRegisteredRpcSigningCapability
  , resolveActiveRegisteredRpcSigningCapability
  , renderRegisteredRpcSigningError
  )
where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( ControlPlaneSigningKeyRef
  , controlPlaneSigningKeyName
  , controlPlaneSigningKeyPrincipal
  , controlPlaneSigningKeyRefFromName
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , mkRequestSigningCapability
  )
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.Vault.Client
  ( TransitSignature (..)
  , TransitSigningKeyInfo (..)
  , vaultReadClusterIncarnation
  , vaultReadTransitSigningKeyVersion
  , vaultTransitSignEd25519AtVersion
  )
import Prodbox.Vault.Session (VaultSession, sessionAddress, withSessionToken)

newtype RpcKeyRegistryObserver m = RpcKeyRegistryObserver
  { observeRpcKeyRegistry :: m (Either RpcKeyRegistryError RpcKeyRegistry)
  }

-- Native observation/signing cannot read a registry or mint a checked RPC
-- capability. The fixed bootstrap metadata reader consumes this projection;
-- ordinary checked signing composes the retained registry separately below.
data NativeRpcSigningProgram result where
  ReadRpcNativeOrigin :: NativeRpcSigningProgram RpcKeyOrigin
  ReadRpcNativePublic :: Natural -> NativeRpcSigningProgram (Natural, ByteString)
  SignRpcNative :: Natural -> ByteString -> NativeRpcSigningProgram (Natural, ByteString)

newtype NativeRpcSigningInterpreter m = NativeRpcSigningInterpreter
  { runNativeRpcSigningProgram
      :: forall result. NativeRpcSigningProgram result -> m (Either RegisteredRpcSigningError result)
  }

data RegisteredRpcSigningProgram result where
  ReadRegisteredRpcNativeOrigin :: RegisteredRpcSigningProgram RpcKeyOrigin
  ReadRegisteredRpcNativePublic :: Natural -> RegisteredRpcSigningProgram (Natural, ByteString)
  ReadRegisteredRpcRegistry :: RegisteredRpcSigningProgram RpcKeyRegistry
  SignRegisteredRpcNative
    :: Natural -> ByteString -> RegisteredRpcSigningProgram (Natural, ByteString)

newtype RegisteredRpcSigningInterpreter m = RegisteredRpcSigningInterpreter
  { runRegisteredRpcSigningProgram
      :: forall result
       . RegisteredRpcSigningProgram result
      -> m (Either RegisteredRpcSigningError result)
  }

data RegisteredRpcSigningError
  = RpcSigningOriginUnavailable
  | RpcSigningOriginMismatch
  | RpcSigningPublicUnavailable
  | RpcSigningPublicMismatch
  | RpcSigningRegistryUnavailable !RpcKeyRegistryError
  | RpcSigningRegistryScopeMismatch
  | RpcSigningBindingChanged
  | RpcSigningBindingRefused !RpcKeyRegistryError
  | RpcSigningSignatureUnavailable
  | RpcSigningNativeVersionMismatch
  | RpcSigningCapabilityInvalid
  deriving stock (Eq, Show)

vaultRegisteredRpcSigningInterpreter
  :: AuthorityScope
  -> AuthorityScope
  -> ControlPlaneSigningKeyRef
  -> VaultSession
  -> RpcKeyRegistryObserver IO
  -> RegisteredRpcSigningInterpreter IO
vaultRegisteredRpcSigningInterpreter authorityScope localScope ref session observer =
  RegisteredRpcSigningInterpreter interpret
 where
  native = vaultNativeRpcSigningInterpreter localScope ref session
  interpret :: RegisteredRpcSigningProgram result -> IO (Either RegisteredRpcSigningError result)
  interpret program
    | controlPlaneSigningKeyRefFromName (controlPlaneSigningKeyName ref) /= Just ref =
        pure (Left RpcSigningOriginMismatch)
    | otherwise = case program of
        ReadRegisteredRpcNativeOrigin -> runNativeRpcSigningProgram native ReadRpcNativeOrigin
        ReadRegisteredRpcNativePublic version -> runNativeRpcSigningProgram native (ReadRpcNativePublic version)
        SignRegisteredRpcNative version bytes -> runNativeRpcSigningProgram native (SignRpcNative version bytes)
        ReadRegisteredRpcRegistry -> do
          result <- observeRpcKeyRegistry observer
          pure $ do
            registry <- first RpcSigningRegistryUnavailable result
            unless (rpcKeyRegistryScope registry == authorityScope) (Left RpcSigningRegistryScopeMismatch)
            pure registry

vaultNativeRpcSigningInterpreter
  :: AuthorityScope
  -> ControlPlaneSigningKeyRef
  -> VaultSession
  -> NativeRpcSigningInterpreter IO
vaultNativeRpcSigningInterpreter localScope ref session = NativeRpcSigningInterpreter interpret
 where
  interpret :: NativeRpcSigningProgram result -> IO (Either RegisteredRpcSigningError result)
  interpret program
    | controlPlaneSigningKeyRefFromName (controlPlaneSigningKeyName ref) /= Just ref =
        pure (Left RpcSigningOriginMismatch)
    | otherwise = case program of
        ReadRpcNativeOrigin -> do
          result <- withSessionToken session $ \token -> vaultReadClusterIncarnation (sessionAddress session) token
          pure $ do
            raw <- first (const RpcSigningOriginUnavailable) result
            vault <- first (const RpcSigningOriginUnavailable) (mkRpcVaultIncarnation raw)
            pure (mkRpcKeyOrigin localScope vault ref)
        ReadRpcNativePublic version -> do
          result <- withSessionToken session $ \token ->
            vaultReadTransitSigningKeyVersion
              (sessionAddress session)
              token
              (controlPlaneSigningKeyName ref)
              version
          pure $ do
            info <- first (const RpcSigningPublicUnavailable) result
            unless
              (transitSigningKeyName info == controlPlaneSigningKeyName ref)
              (Left RpcSigningPublicMismatch)
            pure (transitSigningKeyVersion info, transitSigningPublicKey info)
        SignRpcNative version bytes -> do
          result <- withSessionToken session $ \token ->
            vaultTransitSignEd25519AtVersion
              (sessionAddress session)
              token
              (controlPlaneSigningKeyName ref)
              version
              bytes
          pure $ do
            signature <- first (const RpcSigningSignatureUnavailable) result
            pure (transitSignatureKeyVersion signature, transitSignatureBytes signature)

-- Selection is metadata. The existing resolver independently validates the
-- selected binding against the current native source and registry.
resolveActiveRegisteredRpcSigningCapability
  :: (Monad m)
  => RegisteredRpcSigningInterpreter m
  -> RpcKeyRegistry
  -> m (Either RegisteredRpcSigningError (RequestSigningCapability m))
resolveActiveRegisteredRpcSigningCapability interpreter registry = runExceptT $ do
  origin <- ExceptT (runRegisteredRpcSigningProgram interpreter ReadRegisteredRpcNativeOrigin)
  binding <-
    either (throwE . RpcSigningBindingRefused) pure (selectActiveRpcKeyForOrigin origin registry)
  ExceptT (resolveRegisteredRpcSigningCapability interpreter binding)

resolveRegisteredRpcSigningCapability
  :: (Monad m)
  => RegisteredRpcSigningInterpreter m
  -> RpcKeyBinding
  -> m (Either RegisteredRpcSigningError (RequestSigningCapability m))
resolveRegisteredRpcSigningCapability interpreter binding = runExceptT $ do
  validateBinding interpreter binding
  let key = rpcKeyBindingObserved binding
      principal = controlPlaneSigningKeyPrincipal (rpcKeyOriginRef (rpcObservedOrigin key))
  either
    (const (throwE RpcSigningCapabilityInvalid))
    pure
    ( mkRequestSigningCapability
        principal
        (rpcKeyBindingGeneration binding)
        (rpcObservedPublicKey key)
        sign
    )
 where
  sign bytes = first renderRegisteredRpcSigningError <$> runExceptT (signPinned bytes)
  signPinned bytes = do
    validateBinding interpreter binding
    let native = rpcObservedNativeVersion (rpcKeyBindingObserved binding)
    (actualVersion, signature) <-
      ExceptT (runRegisteredRpcSigningProgram interpreter (SignRegisteredRpcNative native bytes))
    unless (actualVersion == native) (throwE RpcSigningNativeVersionMismatch)
    validateBinding interpreter binding
    pure signature

validateBinding
  :: (Monad m)
  => RegisteredRpcSigningInterpreter m
  -> RpcKeyBinding
  -> ExceptT RegisteredRpcSigningError m ()
validateBinding interpreter binding = do
  unless
    (rpcKeyBindingStatus binding == RpcKeyActive)
    (throwE (RpcSigningBindingRefused RpcKeyAlreadyRetired))
  let key = rpcKeyBindingObserved binding
      origin = rpcObservedOrigin key
      native = rpcObservedNativeVersion key
  actualOrigin <- ExceptT (runRegisteredRpcSigningProgram interpreter ReadRegisteredRpcNativeOrigin)
  unless (actualOrigin == origin) (throwE RpcSigningOriginMismatch)
  (version, public) <-
    ExceptT (runRegisteredRpcSigningProgram interpreter (ReadRegisteredRpcNativePublic native))
  unless (version == native) (throwE RpcSigningNativeVersionMismatch)
  unless (public == rpcObservedPublicKey key) (throwE RpcSigningPublicMismatch)
  registry <- ExceptT (runRegisteredRpcSigningProgram interpreter ReadRegisteredRpcRegistry)
  current <-
    either (throwE . RpcSigningBindingRefused) pure (lookupActiveRpcKey origin native registry)
  unless (current == binding) (throwE RpcSigningBindingChanged)

renderRegisteredRpcSigningError :: RegisteredRpcSigningError -> Text
renderRegisteredRpcSigningError failure = case failure of
  RpcSigningOriginUnavailable -> "registered-rpc-signing/origin-unavailable"
  RpcSigningOriginMismatch -> "registered-rpc-signing/origin-mismatch"
  RpcSigningPublicUnavailable -> "registered-rpc-signing/public-unavailable"
  RpcSigningPublicMismatch -> "registered-rpc-signing/public-mismatch"
  RpcSigningRegistryUnavailable _ -> "registered-rpc-signing/registry-unavailable"
  RpcSigningRegistryScopeMismatch -> "registered-rpc-signing/registry-scope-mismatch"
  RpcSigningBindingChanged -> "registered-rpc-signing/binding-changed"
  RpcSigningBindingRefused _ -> "registered-rpc-signing/binding-refused"
  RpcSigningSignatureUnavailable -> "registered-rpc-signing/signature-unavailable"
  RpcSigningNativeVersionMismatch -> "registered-rpc-signing/native-version-mismatch"
  RpcSigningCapabilityInvalid -> "registered-rpc-signing/capability-invalid"
