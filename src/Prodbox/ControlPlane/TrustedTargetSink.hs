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
  , trustedTargetSinkAdapter
  , vaultTrustedTargetSink
  )
where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRecordCodec
  ( targetMaterialRecordFromVaultFields
  , targetMaterialRecordToVaultFields
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
  ( TargetSinkCasAdapter (..)
  , TargetSinkCasRequest (..)
  , TargetSinkCasResult (..)
  , TargetSinkObservation (..)
  , TargetSinkRecord (..)
  , TargetSinkVersion
  , mkTargetSinkVersion
  , targetSinkVersionText
  )
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2VersionedSecret (..)
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )
import Text.Read (readMaybe)

-- | A target-local mutation boundary.  Its effects are already bound to the
-- exact sink coordinate, so neither callback accepts a mount, path, endpoint,
-- or target identity.
data TrustedTargetSink m payload = TrustedTargetSink
  { internalTrustedTargetSinkCoordinate :: !TargetClusterSecretSink
  , internalObserveTrustedTargetSink :: m (TargetSinkObservation payload)
  , internalCompareAndSwapTrustedTargetSink
      :: Maybe TargetSinkVersion
      -> TargetSinkRecord payload
      -> m (Either Text ())
  }

mkTrustedTargetSink
  :: TargetClusterSecretSink
  -> m (TargetSinkObservation payload)
  -> (Maybe TargetSinkVersion -> TargetSinkRecord payload -> m (Either Text ()))
  -> TrustedTargetSink m payload
mkTrustedTargetSink coordinate observe compareAndSwap =
  TrustedTargetSink
    { internalTrustedTargetSinkCoordinate = coordinate
    , internalObserveTrustedTargetSink = observe
    , internalCompareAndSwapTrustedTargetSink = compareAndSwap
    }

trustedTargetSinkCoordinate :: TrustedTargetSink m payload -> TargetClusterSecretSink
trustedTargetSinkCoordinate = internalTrustedTargetSinkCoordinate

observeTrustedTargetSink
  :: TrustedTargetSink m payload
  -> m (TargetSinkObservation payload)
observeTrustedTargetSink = internalObserveTrustedTargetSink

-- | Adapt a fixed trusted sink to the generic target protocol.  Complete sink
-- equality is checked before either effect.  After every conditional mutation
-- attempt, including an ambiguous/lost response, a fresh observation decides
-- whether the exact requested record is present.
trustedTargetSinkAdapter
  :: (Eq payload, Monad m)
  => TrustedTargetSink m payload
  -> TargetSinkCasAdapter m payload
trustedTargetSinkAdapter trusted =
  TargetSinkCasAdapter
    { targetSinkObserve = observeRequested
    , targetSinkCompareAndSwap = compareAndSwapRequested
    }
 where
  exact = internalTrustedTargetSinkCoordinate trusted

  observeRequested requested
    | requested /= exact =
        pure (TargetSinkUnobservable "target sink coordinate mismatch")
    | otherwise = internalObserveTrustedTargetSink trusted

  compareAndSwapRequested request =
    case trustedRequestParts exact request of
      Left detail -> pure (TargetSinkCasRefused detail)
      Right (expectedVersion, desired) -> do
        attempted <-
          internalCompareAndSwapTrustedTargetSink
            trusted
            expectedVersion
            desired
        observed <- internalObserveTrustedTargetSink trusted
        pure $ case observed of
          TargetSinkObserved revision actual
            | actual == desired -> TargetSinkCasApplied revision actual
          TargetSinkUnobservable detail ->
            TargetSinkCasUnobservable
              (attemptDetail attempted <> "target sink read-back unavailable: " <> detail)
          TargetSinkChanging detail ->
            TargetSinkCasUnobservable
              (attemptDetail attempted <> "target sink read-back changing: " <> detail)
          other -> TargetSinkCasConflict other

  attemptDetail result = case result of
    Right () -> ""
    Left detail -> "target sink mutation response unavailable: " <> detail <> "; "

trustedRequestParts
  :: TargetClusterSecretSink
  -> TargetSinkCasRequest payload
  -> Either Text (Maybe TargetSinkVersion, TargetSinkRecord payload)
trustedRequestParts exact request = case request of
  TargetSinkInitialize requested record
    | requested == exact -> Right (Nothing, record)
    | otherwise -> Left "target sink coordinate mismatch"
  TargetSinkReplace requested version record
    | requested == exact -> Right (Just version, record)
    | otherwise -> Left "target sink coordinate mismatch"

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
            (compareAndSwapVaultTargetSink session sink)
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

compareAndSwapVaultTargetSink
  :: VaultSession
  -> TargetClusterSecretSink
  -> Maybe TargetSinkVersion
  -> TargetSinkRecord TargetSecretPayload
  -> IO (Either Text ())
compareAndSwapVaultTargetSink session sink expected record =
  case (vaultExpectedVersion expected, encodeVaultTargetRecord record) of
    (Left detail, _) -> pure (Left detail)
    (_, Left detail) -> pure (Left detail)
    (Right expectedVersion, Right fields) -> do
      result <-
        withSessionToken session $ \token ->
          vaultKvCasWriteV2
            (sessionAddress session)
            token
            (targetSecretSinkVaultMount sink)
            (targetSecretSinkKvPath sink)
            (KvV2Cas expectedVersion)
            fields
      pure (first (Text.pack . renderHttpError) (void result))

vaultExpectedVersion :: Maybe TargetSinkVersion -> Either Text Natural
vaultExpectedVersion maybeVersion = case maybeVersion of
  Nothing -> Right 0
  Just version ->
    case readMaybe (Text.unpack (targetSinkVersionText version)) of
      Just value | value > 0 -> Right value
      _ -> Left "target sink version is not a positive Vault KV version"

decodeVaultTargetObservation
  :: TargetClusterSecretSink
  -> KvV2VersionedSecret
  -> Either Text (TargetSinkObservation TargetSecretPayload)
decodeVaultTargetObservation sink versioned = do
  if kvV2VersionedSecretVersion versioned == 0
    then Left "target Vault returned a zero KV version"
    else Right ()
  version <-
    first
      (Text.pack . show)
      (mkTargetSinkVersion (Text.pack (show (kvV2VersionedSecretVersion versioned))))
  target <-
    maybe (Left "target sink is outside the compiled registry") Right (targetSecretIdForSink sink)
  record <- targetMaterialRecordFromVaultFields target (kvV2VersionedSecretData versioned)
  pure (TargetSinkObserved version record)

encodeVaultTargetRecord
  :: TargetSinkRecord TargetSecretPayload
  -> Either Text (Map Text Text)
encodeVaultTargetRecord = targetMaterialRecordToVaultFields
