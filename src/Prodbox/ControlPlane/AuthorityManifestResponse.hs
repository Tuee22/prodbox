{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Opt-in Authority read responses using the independently pinned manifest
-- key. No generic signing capability leaves this module. The caller owns the
-- original deadline, physical key provenance, replay and resource admission.
module Prodbox.ControlPlane.AuthorityManifestResponse
  ( AuthorityManifestResponseError (..)
  , authorityManifestSignedObservationHandler
  , rpcBirthManifestSignedRegistryHandler
  , rpcBirthManifestSignedDescriptorHandler
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionRepository)
import Prodbox.ControlPlane.AuthorityAuthenticatedResponse
import Prodbox.ControlPlane.AuthorityControlProtocol (isEpochPromotionObservationForRole)
import Prodbox.ControlPlane.AuthorityPeerContext (AuthorityPeerContextInterpreter)
import Prodbox.ControlPlane.AuthorityPeerContextEndpoint (isAuthorityPeerContextObservationForRole)
import Prodbox.ControlPlane.AuthoritySignedObservationEndpoint (authoritySignedObservationHandler)
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
import Prodbox.ControlPlane.RpcAdmissionBirth (RpcBirthServingMode)
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
  ( rpcBirthSignedDescriptorHandler
  , rpcBirthSignedRegistryHandler
  )
import Prodbox.ControlPlane.RpcAdmissionBirthNative (RpcBirthNativeBackend)
import Prodbox.ControlPlane.RpcAdmissionBirthWire
  ( rpcBirthSignedDescriptorRequest
  , rpcBirthSignedRegistryRequest
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport (AuthorityManifestSigner (..))
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( ManifestPublicKey
  , manifestPublicKeyBytes
  , manifestPublicKeyDigest
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthorityManifestResponseError
  = ManifestResponseKeyUnavailable
  | ManifestResponseKeyMismatch
  | ManifestResponseKeyInvalid
  | ManifestResponseHandlerUnavailable
  | ManifestResponseSigningRefused !AuthorityAuthenticatedResponseError
  deriving stock (Eq, Show)

authorityManifestSignedObservationHandler
  :: Int
  -> Int
  -> AuthorityScope
  -> AuthorityPeerContextInterpreter IO
  -> AuthorityAdmissionRepository IO revision
  -> FrameDigest
  -> AuthorityManifestSigner IO
  -> VerifiedControlPlaneRequest
  -> IO (Maybe (Either AuthorityManifestResponseError ByteString))
authorityManifestSignedObservationHandler maximumRequest maximumResponse scope peer repository expected signer request
  | not (isAuthoritySignedObservation request && ownsRoute) = pure Nothing
  | otherwise = Just <$> withManifestSigner expected signer invoke
 where
  route = verifiedRequestRoute request
  body = verifiedRequestBody request
  ownsRoute =
    isAuthorityPeerContextObservationForRole LifecycleAuthorityRuntime route body
      || isEpochPromotionObservationForRole LifecycleAuthorityRuntime route body
  invoke capability =
    authoritySignedObservationHandler
      maximumRequest
      maximumResponse
      scope
      peer
      repository
      capability
      request

rpcBirthManifestSignedRegistryHandler
  :: AuthorityScope
  -> RpcBirthServingMode
  -> RpcBirthNativeBackend
  -> FrameDigest
  -> AuthorityManifestSigner IO
  -> VerifiedControlPlaneRequest
  -> IO (Maybe (Either AuthorityManifestResponseError ByteString))
rpcBirthManifestSignedRegistryHandler scope mode backend expected signer request
  | not (isAuthoritySignedObservation request)
      || verifiedRequestRoute request /= LifecycleMigrationApply
      || verifiedRequestBody request /= rpcBirthSignedRegistryRequest =
      pure Nothing
  | otherwise = Just <$> withManifestSigner expected signer invoke
 where
  invoke capability = rpcBirthSignedRegistryHandler scope mode backend capability request

rpcBirthManifestSignedDescriptorHandler
  :: AuthorityScope
  -> RpcBirthServingMode
  -> RpcBirthNativeBackend
  -> FrameDigest
  -> AuthorityManifestSigner IO
  -> VerifiedControlPlaneRequest
  -> IO (Maybe (Either AuthorityManifestResponseError ByteString))
rpcBirthManifestSignedDescriptorHandler scope mode backend expected signer request
  | not (isAuthoritySignedObservation request)
      || verifiedRequestRoute request /= LifecycleMigrationApply
      || verifiedRequestBody request /= rpcBirthSignedDescriptorRequest =
      pure Nothing
  | otherwise = Just <$> withManifestSigner expected signer invoke
 where
  invoke capability = rpcBirthSignedDescriptorHandler scope mode backend capability request

withManifestSigner
  :: FrameDigest
  -> AuthorityManifestSigner IO
  -> (RequestSigningCapability IO -> IO (Maybe (Either AuthorityAuthenticatedResponseError ByteString)))
  -> IO (Either AuthorityManifestResponseError ByteString)
withManifestSigner expected signer invoke = do
  initial <- readPinned expected signer
  case initial of
    Left failure -> pure (Left failure)
    Right key@(generation, public) -> case mkSigningKeyGeneration generation of
      Left _ -> pure (Left ManifestResponseKeyInvalid)
      Right wireGeneration -> case mkRequestSigningCapability
        (CallerService LifecycleAuthorityRuntime)
        wireGeneration
        (manifestPublicKeyBytes public)
        (signPinned key) of
        Left _ -> pure (Left ManifestResponseKeyInvalid)
        Right capability -> do
          result <- invoke capability
          case result of
            Nothing -> pure (Left ManifestResponseHandlerUnavailable)
            Just (Left failure) -> pure (Left (ManifestResponseSigningRefused failure))
            Just (Right bytes) -> do
              closing <- readPinned expected signer
              pure $ case closing of
                Left failure -> Left failure
                Right value
                  | value == key -> Right bytes
                  | otherwise -> Left ManifestResponseKeyMismatch
 where
  signPinned key bytes = do
    before <- readPinned expected signer
    case before of
      Right value | value == key -> do
        signed <- signAuthorityManifestPayload signer bytes
        after <- readPinned expected signer
        pure $ case (signed, after) of
          (Right (version, signature), Right closing)
            | version == fst key && closing == key -> Right signature
          _ -> Left ("manifest response signing unavailable" :: Text)
      _ -> pure (Left "manifest response key changed")

readPinned
  :: FrameDigest
  -> AuthorityManifestSigner IO
  -> IO (Either AuthorityManifestResponseError (Natural, ManifestPublicKey))
readPinned expected signer = do
  result <- readAuthorityManifestPublicKey signer
  pure $ case result of
    Left _ -> Left ManifestResponseKeyUnavailable
    Right value@(generation, public)
      | generation == 0 || generation > fromIntegral (maxBound :: Word64) ->
          Left ManifestResponseKeyInvalid
      | manifestPublicKeyDigest public /= expected -> Left ManifestResponseKeyMismatch
      | otherwise -> Right value
