{-# LANGUAGE DerivingStrategies #-}

-- | Select an Authority response key from an independently obtained retained
-- snapshot. This does not authenticate the repository or native key origin.
module Prodbox.ControlPlane.AuthorityResponseTrust
  ( AuthorityResponseTrust
  , AuthorityResponseTrustError (..)
  , selectAuthorityResponseTrust
  , checkAuthorityResponseTrust
  , authorityResponseTrustKey
  , authorityResponseTrustSnapshot
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
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthorityResponseTrust revision
  = AuthorityResponseTrust
      !AuthorityScope
      !RpcKeyOrigin
      !RpcKeyBinding
      !(AuthorityAdmissionSnapshot revision)
      !TrustedRequestKey

data AuthorityResponseTrustError
  = AuthorityResponseRegistryMissing
  | AuthorityResponseRegistryScopeMismatch
  | AuthorityResponseOriginScopeMismatch
  | AuthorityResponseOriginRoleMismatch
  | AuthorityResponseKeyUnavailable !RpcKeyRegistryError
  | AuthorityResponseKeyInvalid
  | AuthorityResponseSnapshotChanged
  deriving stock (Eq, Show)

selectAuthorityResponseTrust
  :: AuthorityScope
  -> RpcKeyOrigin
  -> AuthorityAdmissionSnapshot revision
  -> Either AuthorityResponseTrustError (AuthorityResponseTrust revision)
selectAuthorityResponseTrust scope origin snapshot = do
  unless (rpcKeyOriginScope origin == scope) (Left AuthorityResponseOriginScopeMismatch)
  unless
    (controlPlaneSigningKeyPrincipal (rpcKeyOriginRef origin) == CallerService LifecycleAuthorityRuntime)
    (Left AuthorityResponseOriginRoleMismatch)
  registry <-
    maybe
      (Left AuthorityResponseRegistryMissing)
      Right
      (authorityAggregateRpcKeyRegistry (authorityAdmissionSnapshotState snapshot))
  unless (rpcKeyRegistryScope registry == scope) (Left AuthorityResponseRegistryScopeMismatch)
  binding <- first AuthorityResponseKeyUnavailable (selectActiveRpcKeyForOrigin origin registry)
  let observed = rpcKeyBindingObserved binding
  key <-
    first (const AuthorityResponseKeyInvalid) $
      mkTrustedRequestKey
        (CallerService LifecycleAuthorityRuntime)
        (rpcKeyBindingGeneration binding)
        (rpcObservedPublicKey observed)
  pure (AuthorityResponseTrust scope origin binding snapshot key)

-- | The enclosing operation must obtain this closing snapshot independently.
-- A match does not prevent a later change; a subsequent write must still use
-- the same revision or another separately fenced protocol.
checkAuthorityResponseTrust
  :: (Eq revision)
  => AuthorityResponseTrust revision
  -> AuthorityAdmissionSnapshot revision
  -> Either AuthorityResponseTrustError ()
checkAuthorityResponseTrust (AuthorityResponseTrust scope origin binding initial _) closing = do
  unless
    (authorityAdmissionRevision initial == authorityAdmissionRevision closing)
    (Left AuthorityResponseSnapshotChanged)
  AuthorityResponseTrust _ _ actual _ _ <- selectAuthorityResponseTrust scope origin closing
  unless (actual == binding) (Left AuthorityResponseSnapshotChanged)

authorityResponseTrustKey :: AuthorityResponseTrust revision -> TrustedRequestKey
authorityResponseTrustKey (AuthorityResponseTrust _ _ _ _ key) = key

authorityResponseTrustSnapshot
  :: AuthorityResponseTrust revision -> AuthorityAdmissionSnapshot revision
authorityResponseTrustSnapshot (AuthorityResponseTrust _ _ _ snapshot _) = snapshot
