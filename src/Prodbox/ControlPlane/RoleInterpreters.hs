{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the library-level 'RoleInterpreter' builders that compose a
-- standing role's landed endpoint handlers into the pure dispatch seam
-- ('Prodbox.ControlPlane.Server').
--
-- Each per-role endpoint module ('MigrationEndpoint', 'OperationEndpoint',
-- 'TlsRetentionEndpoint', …) fronts one route's pure algebra over an injected
-- repository and projects the outcome onto @(status, summary)@. 'Server' owns the
-- request/dispatch/response seam but, until a role binds handlers, installs
-- 'Prodbox.ControlPlane.Server.failClosedInterpreter' (every owned route @503@).
-- This module is the missing composition between the two: it builds a role's
-- 'RoleInterpreter' from injected repositories plus an injected readiness probe, so
-- every route the role owns dispatches to its handler through
-- 'Prodbox.ControlPlane.Server.serveControlPlaneRequest'.
--
-- The builders are pure/monad-generic over the injected repositories, so an
-- in-memory fixture drives every route/arm through the seam without a live cluster,
-- Vault, or object store. Supplying the concrete production repositories (over the
-- role's Kubernetes-auth Vault session and in-cluster MinIO Service DNS) and
-- installing the built interpreter in @runControlPlaneRole@ over a real socket
-- remain the live-coupled follow-ons (Standard O), exactly as for the endpoints.
--
-- Only the roles whose every owned route already has both a landed request handler
-- and a landed @(status, summary)@ projection get a complete builder here: the
-- Lifecycle Authority (@migration/apply@ + @operations/submit@ +
-- @operations/observe@), TLS Retention (@store@ + @restore@), Authority Backup
-- (@copy@ + @observe@), and the Provider Worker (@apply@ + @observe@). Only the
-- Target Secret Agent's @complete@ arm (deliberately opaque so a @complete@ request
-- cannot reconstruct a readback — Standard-O agent binding) is not yet landed, so
-- that single role keeps the shared fail-closed interpreter rather than a
-- partially-bound one.
module Prodbox.ControlPlane.RoleInterpreters
  ( lifecycleAuthorityInterpreter
  , tlsRetentionInterpreter
  , authorityBackupInterpreter
  , providerWorkerInterpreter
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupRepository
  , authorityBackupHttpStatus
  , authorityBackupObserveStatus
  , authorityBackupObserveSummary
  , authorityBackupSummary
  , serveBackupCopyRequest
  , serveBackupObserve
  )
import Prodbox.ControlPlane.Codec (controlPlaneRequestCodecToken)
import Prodbox.ControlPlane.MigrationEndpoint
  ( migrationEndpointHttpStatus
  , migrationEndpointSummary
  , serveMigrationApply
  )
import Prodbox.ControlPlane.OperationEndpoint
  ( OperationSubmissionRepository
  , operationObserveHttpStatus
  , operationObserveSummary
  , operationSubmitHttpStatus
  , operationSubmitSummary
  , serveOperationObserveRequest
  , serveOperationSubmitRequest
  )
import Prodbox.ControlPlane.ProviderWorkEndpoint
  ( ProviderWorkRepository
  , providerWorkApplyHttpStatus
  , providerWorkApplySummary
  , providerWorkObserveStatus
  , providerWorkObserveSummary
  , serveProviderWorkApplyRequest
  , serveProviderWorkObserve
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute
      ( AuthorityBackupCopy
      , AuthorityBackupObserve
      , LifecycleMigrationApply
      , LifecycleOperationObserve
      , LifecycleOperationSubmit
      , ProviderWorkApply
      , ProviderWorkObserve
      , TlsRetentionRestore
      , TlsRetentionStore
      )
  )
import Prodbox.ControlPlane.Server
  ( RoleInterpreter (RoleInterpreter, interpreterHandle, interpreterReadyz)
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsRetentionRepository
  , serveTlsRestoreRequest
  , serveTlsStoreRequest
  , tlsRetentionHttpStatus
  , tlsRetentionSummary
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter (MigrationRepository)

-- | Build the Lifecycle Authority role's interpreter, binding all three of its
-- owned routes to their landed handlers over the injected retained repositories:
-- @migration/apply@ → 'serveMigrationApply', @operations/submit@ →
-- 'serveOperationSubmitRequest', and @operations/observe@ →
-- 'serveOperationObserveRequest'. @maximumBytes@ bounds each request body;
-- @readyz@ is the injected readiness probe. Every route the role owns resolves to a
-- handler, so no owned route falls through to @503 interpreter-unavailable@.
lifecycleAuthorityInterpreter
  :: (Monad m)
  => Int
  -> m Bool
  -> MigrationRepository m revision
  -> OperationSubmissionRepository m
  -> RoleInterpreter m
lifecycleAuthorityInterpreter maximumBytes readyz migrationRepository submissionRepository =
  RoleInterpreter
    { interpreterReadyz = readyz
    , interpreterHandle = handle
    }
 where
  handle route body = case route of
    LifecycleMigrationApply -> do
      result <- serveMigrationApply maximumBytes migrationRepository (LazyByteString.fromStrict body)
      pure (Just (migrationEndpointHttpStatus result, encodeSummary (migrationEndpointSummary result)))
    LifecycleOperationSubmit -> do
      result <-
        serveOperationSubmitRequest maximumBytes submissionRepository (LazyByteString.fromStrict body)
      pure (Just (operationSubmitHttpStatus result, encodeSummary (operationSubmitSummary result)))
    LifecycleOperationObserve -> do
      outcome <-
        serveOperationObserveRequest maximumBytes submissionRepository (LazyByteString.fromStrict body)
      pure . Just $ case outcome of
        Right status -> (operationObserveHttpStatus status, encodeSummary (operationObserveSummary status))
        Left err -> (400, encodeSummary ("operation-observe-bad-request:" <> controlPlaneRequestCodecToken err))
    _ -> pure Nothing

-- | Build the TLS Retention role's interpreter, binding both owned routes to their
-- landed handlers over the injected retention repository: @store@ →
-- 'serveTlsStoreRequest' and @restore@ → 'serveTlsRestoreRequest', both projecting
-- through 'tlsRetentionHttpStatus' / 'tlsRetentionSummary'.
tlsRetentionInterpreter
  :: (Monad m)
  => Int
  -> m Bool
  -> TlsRetentionRepository m
  -> RoleInterpreter m
tlsRetentionInterpreter maximumBytes readyz repository =
  RoleInterpreter
    { interpreterReadyz = readyz
    , interpreterHandle = handle
    }
 where
  handle route body = case route of
    TlsRetentionStore -> do
      result <- serveTlsStoreRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (tlsRetentionHttpStatus result, encodeSummary (tlsRetentionSummary result)))
    TlsRetentionRestore -> do
      result <- serveTlsRestoreRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (tlsRetentionHttpStatus result, encodeSummary (tlsRetentionSummary result)))
    _ -> pure Nothing

-- | Build the Authority Backup role's interpreter, binding both owned routes to
-- their landed handlers over the injected admission-state repository: @copy@ →
-- 'serveBackupCopyRequest' (decode the bounded canonical command, decide the
-- backup-repair transition, and compare-and-swap only a genuine advance) and
-- @observe@ → 'serveBackupObserve' (read the current admission state, no mutation).
-- Every route the role owns resolves to a handler, so no owned route falls through
-- to @503 interpreter-unavailable@. The concrete retained-store CAS repository is the
-- live-coupled follow-on (Standard-O), exactly as for the other role interpreters.
authorityBackupInterpreter
  :: (Monad m)
  => Int
  -> m Bool
  -> AuthorityBackupRepository m
  -> RoleInterpreter m
authorityBackupInterpreter maximumBytes readyz repository =
  RoleInterpreter
    { interpreterReadyz = readyz
    , interpreterHandle = handle
    }
 where
  handle route body = case route of
    AuthorityBackupCopy -> do
      result <- serveBackupCopyRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (authorityBackupHttpStatus result, encodeSummary (authorityBackupSummary result)))
    AuthorityBackupObserve -> do
      state <- serveBackupObserve repository
      pure
        (Just (authorityBackupObserveStatus state, encodeSummary (authorityBackupObserveSummary state)))
    _ -> pure Nothing

-- | Build the fenced Provider Worker role's interpreter, binding both owned routes
-- to their landed handlers over the injected provider-work repository: @apply@ →
-- 'serveProviderWorkApplyRequest' (decode the bounded canonical command, re-validate
-- its references, decide admission/idempotency/close/recover through the
-- narrow-session fence, and compare-and-swap only a genuine advance) and @observe@ →
-- 'serveProviderWorkObserve' (read the current session state, no mutation). Every
-- route the role owns resolves to a handler, so no owned route falls through to
-- @503 interpreter-unavailable@. Binding an admitted decision to the real
-- narrow-session provider execution and the concrete retained-store CAS repository
-- are the live-coupled follow-ons (Standard-O), exactly as for the other roles.
providerWorkerInterpreter
  :: (Monad m)
  => Int
  -> m Bool
  -> ProviderWorkRepository m
  -> RoleInterpreter m
providerWorkerInterpreter maximumBytes readyz repository =
  RoleInterpreter
    { interpreterReadyz = readyz
    , interpreterHandle = handle
    }
 where
  handle route body = case route of
    ProviderWorkApply -> do
      result <- serveProviderWorkApplyRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (providerWorkApplyHttpStatus result, encodeSummary (providerWorkApplySummary result)))
    ProviderWorkObserve -> do
      state <- serveProviderWorkObserve repository
      pure
        (Just (providerWorkObserveStatus state, encodeSummary (providerWorkObserveSummary state)))
    _ -> pure Nothing

encodeSummary :: Text -> ByteString
encodeSummary = TextEncoding.encodeUtf8
