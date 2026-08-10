{-# LANGUAGE OverloadedStrings #-}

-- | Target-Agent-local Vault KV mutation capability.
--
-- This module deliberately has no Authority checkpoint, lease repository, or
-- global-CAS dependency.  A 'TrustedTargetSink' fixes the complete target
-- coordinate before it acquires effects; mutation accepts only an expected
-- local version and a validated record.  Every attempted write, including an
-- ambiguous or response-lost write, is decided by an authoritative read-back.
module Prodbox.ControlPlane.TrustedTargetSink
  ( TrustedTargetSink
  , mkTrustedTargetSink
  , trustedTargetSinkCoordinate
  , observeTrustedTargetSink
  , vaultTrustedTargetSink
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.TargetMaterialRecordCodec
  ( targetMaterialRecordFromVaultFields
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretPayload
  , targetSecretIdForSink
  )
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetSinkObservation (..)
  )
import Prodbox.Lifecycle.TargetSinkVersion.Internal
  ( targetSinkVersionFromStoreVersion
  )
import Prodbox.Vault.Client
  ( KvV2VersionedSecret (..)
  , vaultKvReadVersionedV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

-- | A target-local __observation__ boundary.  Its effect is already bound to
-- the exact sink coordinate, so the callback accepts no mount, path, endpoint,
-- or target identity.
--
-- Sprint 4.59 removed the compare-and-swap half. It existed only to serve the
-- in-controller Target Agent write lane, which had zero production callers and
-- is deleted with it; the deployed writer is
-- @TargetSecretWorker.applyCas@ → @targetWorkerCompareAndSwap@, gated by a
-- required opaque @TargetWorkerAttestation@. What survives here is observe-only
-- and is still consumed by the decommission inventory boundary.
data TrustedTargetSink m payload = TrustedTargetSink
  { internalTrustedTargetSinkCoordinate :: !TargetClusterSecretSink
  , internalObserveTrustedTargetSink :: m (TargetSinkObservation payload)
  }

mkTrustedTargetSink
  :: TargetClusterSecretSink
  -> m (TargetSinkObservation payload)
  -> TrustedTargetSink m payload
mkTrustedTargetSink coordinate observe =
  TrustedTargetSink
    { internalTrustedTargetSinkCoordinate = coordinate
    , internalObserveTrustedTargetSink = observe
    }

trustedTargetSinkCoordinate :: TrustedTargetSink m payload -> TargetClusterSecretSink
trustedTargetSinkCoordinate = internalTrustedTargetSinkCoordinate

observeTrustedTargetSink
  :: TrustedTargetSink m payload
  -> m (TargetSinkObservation payload)
observeTrustedTargetSink = internalObserveTrustedTargetSink

-- | Production target-local Vault KV v2 binding over the role's cached
-- Kubernetes-auth session.  The supplied identity must be the process's
-- attested substrate identity.  The exact mount/path comes only from the fixed
-- sink; subsequent effect callbacks cannot substitute it.
vaultTrustedTargetSink
  :: VaultSession
  -> Text
  -> TargetClusterSecretSink
  -> Either Text (TrustedTargetSink IO TargetSecretPayload)
vaultTrustedTargetSink session localIdentity sink
  | Text.null (Text.strip localIdentity) =
      Left "local Target Secret Agent identity is empty"
  | targetSecretIdForSink sink == Nothing =
      Left "target sink is outside the compiled Target Secret Agent Vault allowlist"
  | otherwise =
      Right
        ( mkTrustedTargetSink
            sink
            (observeVaultTargetSink session sink)
        )

observeVaultTargetSink
  :: VaultSession
  -> TargetClusterSecretSink
  -> IO (TargetSinkObservation TargetSecretPayload)
observeVaultTargetSink session sink = do
  result <-
    withSessionToken session $ \token ->
      vaultKvReadVersionedV2
        (sessionAddress session)
        token
        (targetSecretSinkVaultMount sink)
        (targetSecretSinkKvPath sink)
  pure $ case result of
    Left (HttpStatus 404 _) -> TargetSinkMissing
    Left err ->
      TargetSinkUnobservable
        ("target Vault read failed: " <> Text.pack (renderHttpError err))
    Right versioned ->
      either TargetSinkUnobservable id (decodeVaultTargetObservation sink versioned)

decodeVaultTargetObservation
  :: TargetClusterSecretSink
  -> KvV2VersionedSecret
  -> Either Text (TargetSinkObservation TargetSecretPayload)
decodeVaultTargetObservation sink versioned = do
  version <-
    maybe
      (Left "target Vault returned a zero KV version")
      Right
      (targetSinkVersionFromStoreVersion (kvV2VersionedSecretVersion versioned))
  target <-
    maybe (Left "target sink is outside the compiled registry") Right (targetSecretIdForSink sink)
  record <- targetMaterialRecordFromVaultFields target (kvV2VersionedSecretData versioned)
  pure (TargetSinkObserved version record)
