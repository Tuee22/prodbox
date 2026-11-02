{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One closed metadata program. Its native-attested temporary signer never
-- leaves this module: only peer-context refresh and the normal registry read
-- can consume it. Returned registry metadata grants no signing/admission owner.
module Prodbox.ControlPlane.RpcAdmissionBirthBootstrap
  ( RpcBirthBootstrapError (..)
  , observeRpcBirthBootstrapRegistry
  ) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthenticationRegistry (controlPlaneSigningKeyPrincipal)
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneClientError
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleMigrationApplyRoute)
  , callControlPlane
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RegisteredRpcSigning
  ( NativeRpcSigningInterpreter (..)
  , NativeRpcSigningProgram (..)
  , RegisteredRpcSigningError
  )
import Prodbox.ControlPlane.RequestAuthentication (RequestNonce, mkRequestSigningCapability)
import Prodbox.ControlPlane.RpcAdmissionBirth
  ( RpcBirthServingMode
  , rpcBirthServingModeMatches
  , rpcBirthServingModeRequiresRegistration
  )
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
  ( RpcBirthClientError
  , requestRpcBirthRegistryWithin
  )
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
  ( RpcBirthRegistryObservation
  , rpcBirthObservationDescriptor
  , rpcBirthObservationRequiresRegistration
  , rpcBirthObservedRegistry
  , rpcBirthRegistryBirth
  )
import Prodbox.ControlPlane.RpcKeyRegistry
  ( rpcKeyOriginRef
  , rpcObservedNativeVersion
  , rpcObservedPublicKey
  )
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import System.Timeout (timeout)

data RpcBirthBootstrapError
  = RpcBirthBootstrapRegisteredModeRequired
  | RpcBirthBootstrapNative !RegisteredRpcSigningError
  | RpcBirthBootstrapHint !RpcOwnBindingHintError
  | RpcBirthBootstrapHintTransport !ControlPlaneClientError
  | RpcBirthBootstrapHintHttpStatus !Int
  | RpcBirthBootstrapRegistry !RpcBirthClientError
  | RpcBirthBootstrapPinMismatch
  | RpcBirthBootstrapCapabilityInvalid
  | RpcBirthBootstrapClockUnavailable
  | RpcBirthBootstrapDeadlineReached
  | RpcBirthBootstrapTimedOut
  deriving (Eq, Show)

observeRpcBirthBootstrapRegistry
  :: NativeRpcSigningInterpreter IO
  -> IO (Either Text AuthorityTime)
  -> IO (Either Text RequestNonce)
  -> AuthorityScope
  -> RpcBirthServingMode
  -> AuthorityTime
  -> AuthenticatedTransportBounds
  -> ControlPlaneClient 'LifecycleAuthorityRuntime
  -> IO (Either RpcBirthBootstrapError RpcBirthRegistryObservation)
observeRpcBirthBootstrapRegistry native readTime nonce scope mode deadline bounds client =
  withinBootstrap readTime deadline $ runExceptT $ do
    unless
      (rpcBirthServingModeRequiresRegistration mode)
      (throwE RpcBirthBootstrapRegisteredModeRequired)
    origin <- nativeEffect ReadRpcNativeOrigin
    query <- either (throwE . RpcBirthBootstrapHint) pure (mkRpcOwnBindingQuery scope origin)
    response <-
      ExceptT
        ( first RpcBirthBootstrapHintTransport
            <$> callControlPlane client LifecycleMigrationApplyRoute (encodeRpcOwnBindingQuery query)
        )
    hint <- case response of
      ControlPlaneResponse 200 body -> either (throwE . RpcBirthBootstrapHint) pure (decodeRpcOwnBindingHint query body)
      ControlPlaneResponse status _ -> throwE (RpcBirthBootstrapHintHttpStatus status)
    validateHintNative hint
    let observed = rpcOwnBindingHintObserved hint
        version = rpcObservedNativeVersion observed
        sign bytes =
          first (Text.pack . show)
            <$> runExceptT
              ( do
                  validateHintNative hint
                  (actual, signature) <- nativeEffect (SignRpcNative version bytes)
                  unless (actual == version) (throwE (RpcBirthBootstrapHint RpcOwnBindingNativeMismatch))
                  validateHintNative hint
                  pure signature
              )
    signer <-
      either (const (throwE RpcBirthBootstrapCapabilityInvalid)) pure $
        mkRequestSigningCapability
          (controlPlaneSigningKeyPrincipal (rpcKeyOriginRef origin))
          (rpcOwnBindingHintGeneration hint)
          (rpcObservedPublicKey observed)
          sign
    let providers =
          AuthenticatedClientProviders
            (pure (Right signer))
            (pure (Right scope))
            (pure (Right authorityEpochGenesis))
            (pure (Right deadline))
            nonce
        transport = mkAuthenticatedClientTransport bounds providers client
    registry <-
      ExceptT
        (first RpcBirthBootstrapRegistry <$> requestRpcBirthRegistryWithin readTime deadline scope transport)
    let birth = rpcBirthRegistryBirth registry
    descriptor <- maybe (throwE RpcBirthBootstrapPinMismatch) pure (rpcBirthObservationDescriptor birth)
    unless
      (rpcBirthObservationRequiresRegistration birth && rpcBirthServingModeMatches mode descriptor)
      (throwE RpcBirthBootstrapPinMismatch)
    _ <-
      either
        (throwE . RpcBirthBootstrapHint)
        pure
        (confirmRpcOwnBindingHintRegistry hint (rpcBirthObservedRegistry registry))
    validateHintNative hint
    pure registry
 where
  nativeEffect
    :: NativeRpcSigningProgram value -> ExceptT RpcBirthBootstrapError IO value
  nativeEffect program = ExceptT (first RpcBirthBootstrapNative <$> runNativeRpcSigningProgram native program)
  validateHintNative :: RpcOwnBindingHint -> ExceptT RpcBirthBootstrapError IO ()
  validateHintNative hint = do
    origin <- nativeEffect ReadRpcNativeOrigin
    public <-
      nativeEffect (ReadRpcNativePublic (rpcObservedNativeVersion (rpcOwnBindingHintObserved hint)))
    either (throwE . RpcBirthBootstrapHint) pure (confirmRpcOwnBindingHintNative hint origin public)

-- Production additionally wraps the whole program in the original monotonic
-- channel borrow. This Authority-time bound never refreshes a preparation.
withinBootstrap
  :: IO (Either Text AuthorityTime)
  -> AuthorityTime
  -> IO (Either RpcBirthBootstrapError value)
  -> IO (Either RpcBirthBootstrapError value)
withinBootstrap readTime deadline action = do
  observed <- readTime
  case observed of
    Left _ -> pure (Left RpcBirthBootstrapClockUnavailable)
    Right now
      | now >= deadline -> pure (Left RpcBirthBootstrapDeadlineReached)
      | otherwise -> do
          let micros =
                fromIntegral
                  (min (authorityTimeMicros deadline - authorityTimeMicros now) (fromIntegral (maxBound :: Int)))
          attempted <- timeout micros $ do
            result <- action
            case result of
              Left cause -> cause `seq` pure (Left cause)
              Right value -> value `seq` pure (Right value)
          closing <- readTime
          pure $ case closing of
            Left _ -> Left RpcBirthBootstrapClockUnavailable
            Right after
              | after >= deadline -> Left RpcBirthBootstrapDeadlineReached
              | otherwise -> maybe (Left RpcBirthBootstrapTimedOut) id attempted
