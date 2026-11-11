{-# LANGUAGE DerivingStrategies #-}

-- | Select a Target response-verification key from one retained Authority
-- snapshot. Selection alone neither authenticates the snapshot's repository
-- nor proves that the origin belongs to the intended physical Deployment.
module Prodbox.ControlPlane.TargetResponseTrust
  ( TargetResponseTrust
  , TargetResponseTrustError (..)
  , selectTargetResponseTrust
  , targetResponseTrustKey
  , targetResponseTrustSnapshot
  )
where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Prodbox.ControlPlane.AuthenticationRegistry (controlPlaneSigningKeyPrincipal)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionSnapshot (..))
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( CallerPrincipal (CallerService)
  , TrustedRequestKey
  , mkTrustedRequestKey
  )
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.Lifecycle.Authority.Admission (authorityAggregateRpcKeyRegistry)
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

-- The original snapshot is retained for a later compare-and-swap. A caller
-- must still use its revision when recording the independently observed fact.
data TargetResponseTrust revision
  = TargetResponseTrust
      !(AuthorityAdmissionSnapshot revision)
      !TrustedRequestKey

data TargetResponseTrustError
  = TargetResponseRegistryMissing
  | TargetResponseRegistryScopeMismatch
  | TargetResponseOriginRoleMismatch
  | TargetResponseKeyUnavailable !RpcKeyRegistryError
  | TargetResponseKeyInvalid
  deriving stock (Eq, Show)

selectTargetResponseTrust
  :: AuthorityScope
  -> RpcKeyOrigin
  -> AuthorityAdmissionSnapshot revision
  -> Either TargetResponseTrustError (TargetResponseTrust revision)
selectTargetResponseTrust authorityScope origin snapshot = do
  unless
    (controlPlaneSigningKeyPrincipal (rpcKeyOriginRef origin) == CallerService TargetSecretAgentRuntime)
    (Left TargetResponseOriginRoleMismatch)
  registry <-
    maybe
      (Left TargetResponseRegistryMissing)
      Right
      (authorityAggregateRpcKeyRegistry (authorityAdmissionSnapshotState snapshot))
  unless (rpcKeyRegistryScope registry == authorityScope) (Left TargetResponseRegistryScopeMismatch)
  binding <- first TargetResponseKeyUnavailable (selectActiveRpcKeyForOrigin origin registry)
  let observed = rpcKeyBindingObserved binding
  key <-
    first (const TargetResponseKeyInvalid) $
      mkTrustedRequestKey
        (CallerService TargetSecretAgentRuntime)
        (rpcKeyBindingGeneration binding)
        (rpcObservedPublicKey observed)
  pure (TargetResponseTrust snapshot key)

targetResponseTrustKey :: TargetResponseTrust revision -> TrustedRequestKey
targetResponseTrustKey (TargetResponseTrust _ key) = key

targetResponseTrustSnapshot :: TargetResponseTrust revision -> AuthorityAdmissionSnapshot revision
targetResponseTrustSnapshot (TargetResponseTrust snapshot _) = snapshot
