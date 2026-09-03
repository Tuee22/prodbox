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
-- Vault, or object store. The executable runtime supplies the Lifecycle Authority's
-- concrete Kubernetes-auth Vault / in-cluster MinIO repositories; the other role
-- compositions remain independently injectable.
--
-- Every role whose endpoint algebra is landed has a complete builder here.
-- Target material installation is intentionally absent: the standing Target
-- Agent exposes only authenticated, arm-specific metadata and one-shot worker
-- coordination handlers composed by the production runtime.
module Prodbox.ControlPlane.RoleInterpreters
  ( lifecycleAuthorityInterpreter
  , lifecycleAuthorityAdmissionInterpreter
  , lifecycleAuthorityAdmissionAuthenticatedHandler
  , lifecycleAuthorityEksDrainIntentAuthenticatedHandler
  , lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedHandler
  , lifecycleAuthorityAwsStackReaderAuthenticatedHandler
  , lifecycleAuthorityAwsStackCreationBindingAuthenticatedHandler
  , lifecycleAuthorityOwnershipManifestAuthenticatedHandler
  , lifecycleAuthorityControllerOwnerAuthenticatedHandler
  , lifecycleAuthorityRecoveryPlaneAuthenticatedHandler
  , lifecycleAuthorityLocalRke2HostObservationAuthenticatedHandler
  , lifecycleAuthorityCascadeRetainedSlotAuthenticatedHandler
  , LifecycleAuthorityDecommissionInputs (..)
  , lifecycleAuthorityDecommissionAuthenticatedHandler
  , lifecycleAuthorityTlsRetentionAuthenticatedHandler
  , lifecycleAuthorityTlsRetentionWorkflowAuthenticatedHandler
  , lifecycleAuthorityAdminActionExecutionAuthenticatedHandler
  , tlsRetentionInterpreter
  , authorityBackupInterpreter
  , providerWorkerInterpreter
  , targetSecretAgentTlsAuthenticatedHandler
  , TargetSecretAgentDecommissionInputs (..)
  , targetSecretAgentDecommissionAuthenticatedHandler
  , targetSecretAgentAdminActionAuthenticatedHandler
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityExecutionBoundary
  , AdminActionEffectRepository
  , adminActionAuthorityExecutionResponseBody
  , adminActionAuthorityExecutionResponseStatus
  , serveAdminActionAuthorityExecutionRequest
  )
import Prodbox.ControlPlane.AdminActionTargetEndpoint
  ( AdminActionTargetVerification (..)
  , adminActionTargetResponseBody
  , adminCustodyTombstoneResponseStatus
  , adminTargetTombstoneResponseStatus
  , serveAdminCustodyTombstoneRequest
  , serveAdminTargetTombstoneRequest
  )
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository
  , authorityOperationObserveHttpStatus
  , authorityOperationObserveResponseBody
  , authorityOperationSubmitHttpStatus
  , authorityOperationSubmitResponseBody
  , authorityTransitionHttpStatus
  , authorityTransitionSummary
  , serveAuthorityControlRequest
  , serveAuthorityOperationObserveRequest
  , serveAuthorityOperationSubmitRequest
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupRepository
  , authorityBackupCopyResponseBody
  , authorityBackupHttpStatus
  , authorityBackupObserveResponseBody
  , authorityBackupObserveStatus
  , serveBackupCopyRequest
  , serveBackupObserveRequest
  )
import Prodbox.ControlPlane.AuthorityBackupExportEndpoint
  ( authorityBackupExportHttpStatus
  , authorityBackupExportResponseBody
  , serveAuthorityBackupExportRequest
  )
import Prodbox.ControlPlane.AuthorityObservationEndpoint
  ( authorityObservationHttpStatus
  , authorityObservationResponseBody
  , serveLifecycleAuthorityAggregateObserveRequest
  , serveLifecycleAuthorityObserveRequest
  )
import Prodbox.ControlPlane.AwsStackCreationBindingEndpoint
  ( awsStackCreationEndpointBody
  , awsStackCreationEndpointStatus
  , serveAwsStackCreationEndpointRequest
  )
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationBindingRepository
  )
import Prodbox.ControlPlane.AwsStackReaderEndpoint
  ( awsStackReaderEndpointBody
  , awsStackReaderEndpointStatus
  , serveAwsStackReaderEndpointRequest
  )
import Prodbox.ControlPlane.AwsStackReaderRepository
  ( AwsStackReaderClient
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerAdminActionRunner)
  )
import Prodbox.ControlPlane.CascadeRetainedSlotEndpoint
  ( CascadeRetainedSlotEndpointHandler
  , cascadeRetainedSlotEndpointBody
  , cascadeRetainedSlotEndpointStatus
  , serveCascadeRetainedSlotEndpointRequest
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunRepositoryProvider
  , cleanupRunEndpointBody
  , cleanupRunEndpointStatus
  , serveCleanupRunRequest
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigAuthorityRepository
  , configEndpointHttpStatus
  , configEndpointResponseBody
  , serveConfigObserveRequest
  , serveConfigProposeCasRequest
  )
import Prodbox.ControlPlane.ControllerOwnerEndpoint
  ( controllerOwnerEndpointBody
  , controllerOwnerEndpointStatus
  , serveControllerOwnerEndpointRequest
  )
import Prodbox.ControlPlane.ControllerOwnerRepository
  ( ControllerOwnerRepositoryError
  , ControllerOwnerTransition
  )
import Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClient
  )
import Prodbox.ControlPlane.EksDrainIntentEndpoint
  ( eksDrainIntentEndpointBody
  , eksDrainIntentEndpointStatus
  , serveEksDrainIntentEndpointRequest
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
  ( EksDrainReadBackReceiptClient
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptEndpoint
  ( eksDrainReadBackReceiptEndpointBody
  , eksDrainReadBackReceiptEndpointStatus
  , serveEksDrainReadBackReceiptEndpointRequest
  )
import Prodbox.ControlPlane.LocalRke2HostObservationEndpoint
  ( LocalRke2HostObservationEndpointHandler
  , localRke2HostObservationEndpointBody
  , localRke2HostObservationEndpointStatus
  , serveLocalRke2HostObservationEndpointRequest
  )
import Prodbox.ControlPlane.MigrationEndpoint
  ( migrationEndpointHttpStatus
  , migrationEndpointSummary
  , serveAuthorityMigrationApply
  , serveMigrationApply
  )
import Prodbox.ControlPlane.OwnershipManifestEndpoint
  ( ownershipManifestEndpointBody
  , ownershipManifestEndpointStatus
  , serveOwnershipManifestEndpointRequest
  )
import Prodbox.ControlPlane.OwnershipManifestRepository
  ( OwnershipManifestRepository
  )
import Prodbox.ControlPlane.ProjectionImportEndpoint
  ( ProjectionImportHandler
  , projectionImportEndpointHttpStatus
  , projectionImportEndpointSummary
  , runProjectionImportHandler
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
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointHandler
  , pulumiCheckpointResponseBody
  , pulumiCheckpointResponseHttpStatus
  , runPulumiCheckpointHandler
  )
import Prodbox.ControlPlane.RecoveryPlaneEndpoint
  ( RecoveryPlaneEndpointHandler
  , recoveryPlaneEndpointBody
  , recoveryPlaneEndpointStatus
  , serveRecoveryPlaneEndpointRequest
  )
import Prodbox.ControlPlane.RegisteredStackCleanupSelection
  ( RegisteredStackCleanupBoundary
  )
import Prodbox.ControlPlane.RegisteredStackCreationProducer
  ( RegisteredStackCreationBoundary
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot (verifiedCallerSlotPrincipal)
  )
import Prodbox.ControlPlane.RetainedSesLeaseEndpoint
  ( RetainedSesLeaseHandler
  , retainedSesLeaseResponseBody
  , retainedSesLeaseResponseHttpStatus
  , runRetainedSesLeaseHandler
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , constantRoleReadinessSource
  , unobservedRoleReadinessFacts
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute
      ( AuthorityBackupCopy
      , AuthorityBackupObserve
      , LifecycleAdminActionExecution
      , LifecycleAuthorityBackupExport
      , LifecycleAuthorityControl
      , LifecycleAuthorityDecommissionExport
      , LifecycleAuthorityDecommissionStop
      , LifecycleAuthorityObserve
      , LifecycleAwsStackCreationBinding
      , LifecycleAwsStackReader
      , LifecycleCascadeRetainedSlot
      , LifecycleCleanupRun
      , LifecycleConfigObserve
      , LifecycleConfigProposeCas
      , LifecycleControllerOwner
      , LifecycleEksDrainIntent
      , LifecycleEksDrainReadBackReceipt
      , LifecycleLocalRke2HostObservation
      , LifecycleMigrationApply
      , LifecycleOperationObserve
      , LifecycleOperationSubmit
      , LifecycleOwnershipManifest
      , LifecycleProjectionImport
      , LifecyclePulumiCheckpoint
      , LifecycleRecoveryPlane
      , LifecycleRetainedSesLease
      , LifecycleTlsRetentionObserve
      , LifecycleTlsRetentionPromote
      , LifecycleTlsRetentionWorkflow
      , ProviderWorkApply
      , ProviderWorkObserve
      , TargetSecretAdminActionCustodyTombstone
      , TargetSecretAdminActionGenerationTombstone
      , TargetSecretDecommissionCustodyTombstone
      , TargetSecretDecommissionInventory
      , TargetSecretDecommissionTombstone
      , TargetTlsHomeRewrap
      , TargetTlsHomeWrap
      , TargetTlsPrepareExchange
      , TargetTlsRestore
      , TargetTlsRetain
      , TargetTlsVerifySource
      , TlsRetentionRestore
      , TlsRetentionStore
      )
  )
import Prodbox.ControlPlane.Server
  ( RoleInterpreter (RoleInterpreter, interpreterHandle, interpreterReadiness)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretPayload
  )
import Prodbox.ControlPlane.TlsDekExchange (TlsDekTransitBoundary)
import Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
  ( TlsAuthorityRepositoryResolver
  , serveTlsAuthorityObserveRequest
  , serveTlsAuthorityPromoteRequest
  , tlsAuthorityResponseBody
  , tlsAuthorityResponseHttpStatus
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsRetentionRepository
  , serveTlsRestoreRequest
  , serveTlsStoreRequest
  , tlsRestoreHttpStatus
  , tlsRestoreResponseBody
  , tlsStoreHttpStatus
  , tlsStoreResponseBody
  )
import Prodbox.ControlPlane.TlsRetentionWorkflowAuthorityEndpoint
  ( TlsRetentionWorkflowAuthorityBoundary
  , serveTlsRetentionWorkflowAuthorityRequest
  , tlsRetentionWorkflowAuthorityResponseBody
  , tlsRetentionWorkflowAuthorityResponseHttpStatus
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsSecretBoundary
  , serveTlsHomeRewrapRequest
  , serveTlsHomeWrapRequest
  , serveTlsTargetPrepareRequest
  , serveTlsTargetRestoreRequest
  , serveTlsTargetRetainRequest
  , serveTlsTargetVerifyRequest
  , tlsHomeRewrapHttpStatus
  , tlsHomeRewrapResponseBody
  , tlsHomeWrapHttpStatus
  , tlsHomeWrapResponseBody
  , tlsTargetPrepareHttpStatus
  , tlsTargetPrepareResponseBody
  , tlsTargetRestoreHttpStatus
  , tlsTargetRestoreResponseBody
  , tlsTargetRetainHttpStatus
  , tlsTargetRetainResponseBody
  , tlsTargetVerifyHttpStatus
  , tlsTargetVerifyResponseBody
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lib.AwsControlPlaneIsolation (ControllerOwnerState)
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionAuthorityRepository
  )
import Prodbox.Lifecycle.Authority.Admission (AuthorityAdmissionAggregate)
import Prodbox.Lifecycle.Authority.MigrationInterpreter (MigrationRepository)
import Prodbox.Lifecycle.CleanupRun (CleanupDigest, CleanupRunId)
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityDecommissionExportRepository
  , AuthorityManifestSigner
  , authorityDecommissionExportHttpStatus
  , authorityDecommissionExportResponseBody
  , serveAuthorityDecommissionExportRequest
  )
import Prodbox.Lifecycle.Decommission.AuthorityStop
  ( AuthorityDecommissionStopRepository
  , authorityDecommissionStopHttpStatus
  , authorityDecommissionStopResponseBody
  , serveAuthorityDecommissionStopRequest
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( RetainedCustodyBoundary
  , retainedCustodyTombstoneHttpStatus
  , retainedCustodyTombstoneResponseBody
  , serveRetainedCustodyTombstoneRequest
  )
import Prodbox.Lifecycle.Decommission.TargetInventory
  ( TargetDecommissionInventoryBoundary
  , serveTargetDecommissionInventoryRequest
  , targetDecommissionInventoryHttpStatus
  , targetDecommissionInventoryResponseBody
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneRegistry
  , serveTargetGenerationTombstoneRequest
  , targetGenerationTombstoneHttpStatus
  , targetGenerationTombstoneResponseBody
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)

-- | Context-free Lifecycle Authority composition over the retained admission
-- aggregate.  Operation and checkpoint routes deliberately do not appear here: they require
-- a verified caller slot and are exposed only by
-- 'lifecycleAuthorityAdmissionAuthenticatedHandler'.
lifecycleAuthorityAdmissionInterpreter
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> Text
  -> m (Either Text Natural)
  -> (AuthorityAdmissionAggregate -> Either Text ByteString)
  -> AuthorityAdmissionRepository m revision
  -> ProjectionImportHandler m
  -> RetainedSesLeaseHandler m
  -> PulumiCheckpointHandler m
  -> RoleInterpreter m
lifecycleAuthorityAdmissionInterpreter
  maximumBytes
  readiness
  authorityScope
  observeNow
  encodeAggregate
  repository
  projectionImportHandler
  retainedSesLeaseHandler
  _pulumiCheckpointHandler =
    RoleInterpreter
      { interpreterReadiness = readiness
      , interpreterHandle = handle
      }
   where
    handle route body = case route of
      LifecycleAuthorityControl -> do
        result <-
          serveAuthorityControlRequest
            maximumBytes
            repository
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( authorityTransitionHttpStatus result
              , encodeSummary (authorityTransitionSummary result)
              )
          )
      LifecycleAuthorityBackupExport -> do
        result <-
          serveAuthorityBackupExportRequest
            maximumBytes
            encodeAggregate
            repository
            body
        pure
          ( Just
              ( authorityBackupExportHttpStatus result
              , authorityBackupExportResponseBody result
              )
          )
      LifecycleRetainedSesLease -> do
        result <-
          runRetainedSesLeaseHandler
            retainedSesLeaseHandler
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( retainedSesLeaseResponseHttpStatus result
              , retainedSesLeaseResponseBody result
              )
          )
      LifecycleMigrationApply -> do
        result <-
          serveAuthorityMigrationApply
            maximumBytes
            repository
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( migrationEndpointHttpStatus result
              , encodeSummary (migrationEndpointSummary result)
              )
          )
      LifecycleProjectionImport -> do
        result <-
          runProjectionImportHandler
            projectionImportHandler
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( projectionImportEndpointHttpStatus result
              , encodeSummary (projectionImportEndpointSummary result)
              )
          )
      LifecycleAuthorityObserve -> do
        result <-
          serveLifecycleAuthorityAggregateObserveRequest
            maximumBytes
            authorityScope
            observeNow
            repository
            (LazyByteString.fromStrict body)
        pure (Just (authorityObservationHttpStatus result, authorityObservationResponseBody result))
      _ -> pure Nothing

-- | Production Lifecycle Authority handler.  Authentication constructs the
-- opaque caller slot; the operation payload carries only a stable submission
-- key (and digest for submit), so neither a raw body nor a context-free caller
-- can inject a principal, client sequence, or signing-key generation.
lifecycleAuthorityAdmissionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> Text
  -> m (Either Text Natural)
  -> (AuthorityAdmissionAggregate -> Either Text ByteString)
  -> AuthorityAdmissionRepository m revision
  -> ConfigAuthorityRepository m
  -> ProjectionImportHandler m
  -> RetainedSesLeaseHandler m
  -> PulumiCheckpointHandler m
  -> CleanupRunRepositoryProvider m cleanupRevision
  -> AuthenticatedRoleHandler m
lifecycleAuthorityAdmissionAuthenticatedHandler
  maximumBytes
  readiness
  authorityScope
  observeNow
  encodeAggregate
  repository
  configRepository
  projectionImportHandler
  retainedSesLeaseHandler
  pulumiCheckpointHandler
  cleanupRunProvider =
    AuthenticatedRoleHandler
      { authenticatedHandlerReadiness = readiness
      , authenticatedHandlerHandle = handle
      }
   where
    contextFree =
      lifecycleAuthorityAdmissionInterpreter
        maximumBytes
        readiness
        authorityScope
        observeNow
        encodeAggregate
        repository
        projectionImportHandler
        retainedSesLeaseHandler
        pulumiCheckpointHandler
    handle callerSlot route body = case route of
      LifecycleOperationSubmit -> do
        result <-
          serveAuthorityOperationSubmitRequest
            maximumBytes
            repository
            callerSlot
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( authorityOperationSubmitHttpStatus result
              , authorityOperationSubmitResponseBody result
              )
          )
      LifecycleOperationObserve -> do
        result <-
          serveAuthorityOperationObserveRequest
            maximumBytes
            repository
            callerSlot
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( authorityOperationObserveHttpStatus result
              , authorityOperationObserveResponseBody result
              )
          )
      LifecyclePulumiCheckpoint -> do
        result <-
          runPulumiCheckpointHandler
            pulumiCheckpointHandler
            callerSlot
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( pulumiCheckpointResponseHttpStatus result
              , pulumiCheckpointResponseBody result
              )
          )
      LifecycleConfigObserve -> do
        result <-
          serveConfigObserveRequest
            maximumBytes
            configRepository
            callerSlot
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( configEndpointHttpStatus result
              , configEndpointResponseBody result
              )
          )
      LifecycleConfigProposeCas -> do
        result <-
          serveConfigProposeCasRequest
            maximumBytes
            configRepository
            callerSlot
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( configEndpointHttpStatus result
              , configEndpointResponseBody result
              )
          )
      LifecycleCleanupRun -> do
        result <-
          serveCleanupRunRequest
            cleanupRunProvider
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( cleanupRunEndpointStatus result
              , cleanupRunEndpointBody result
              )
          )
      _ -> interpreterHandle contextFree route body

-- | Add the authenticated EKS drain-intent endpoint around the standing
-- Authority handler.  Route authentication and replay admission have already
-- produced the caller slot before this layer runs; the endpoint receives only
-- its closed, versioned request and the retained repository client.
lifecycleAuthorityEksDrainIntentAuthenticatedHandler
  :: (Monad m)
  => EksDrainIntentClient m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityEksDrainIntentAuthenticatedHandler client inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleEksDrainIntent -> do
      result <-
        serveEksDrainIntentEndpointRequest
          client
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( eksDrainIntentEndpointStatus result
            , eksDrainIntentEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the authenticated EKS drain read-back receipt endpoint around the
-- standing Authority handler.  The endpoint itself recovers the retained
-- intent by stable identity and only emits proof-bearing canonical bytes after
-- an independent Authority repository read-back.
lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedHandler
  :: (Monad m)
  => EksDrainReadBackReceiptClient m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedHandler client inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleEksDrainReadBackReceipt -> do
      result <-
        serveEksDrainReadBackReceiptEndpointRequest
          client
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( eksDrainReadBackReceiptEndpointStatus result
            , eksDrainReadBackReceiptEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the independently read-back AWS stack-reader bundle endpoint. Commit
-- responses retain only their write disposition; proof-bearing bytes are
-- returned solely by the separate read-back action.
lifecycleAuthorityAwsStackReaderAuthenticatedHandler
  :: (Monad m)
  => (CleanupRunId -> CleanupDigest -> AwsStackReaderClient m)
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityAwsStackReaderAuthenticatedHandler clientFor inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleAwsStackReader -> do
      result <-
        serveAwsStackReaderEndpointRequest
          clientFor
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( awsStackReaderEndpointStatus result
            , awsStackReaderEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the Authority-reobserved AWS stack-creation binding protocol.  The
-- endpoint receives no caller-minted observation; it combines the exact
-- operation/revision/scope request with the retained admission repository.
lifecycleAuthorityAwsStackCreationBindingAuthenticatedHandler
  :: (Monad m)
  => RegisteredStackCreationBoundary m
  -> RegisteredStackCleanupBoundary m
  -> AwsStackCreationBindingRepository m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityAwsStackCreationBindingAuthenticatedHandler
  producer
  cleanupBoundary
  repository
  inner =
    AuthenticatedRoleHandler
      { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
      , authenticatedHandlerHandle = handle
      }
   where
    handle callerSlot route body = case route of
      LifecycleAwsStackCreationBinding -> do
        result <-
          serveAwsStackCreationEndpointRequest
            producer
            cleanupBoundary
            repository
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( awsStackCreationEndpointStatus result
              , awsStackCreationEndpointBody result
              )
          )
      _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the raw Authority ownership-manifest observation protocol.  Its
-- authenticated transport client alone maps an exact Missing observation to
-- observation-only Absent for the caller's target.
lifecycleAuthorityOwnershipManifestAuthenticatedHandler
  :: (Monad m)
  => OwnershipManifestRepository m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityOwnershipManifestAuthenticatedHandler repository inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleOwnershipManifest -> do
      result <-
        serveOwnershipManifestEndpointRequest
          repository
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( ownershipManifestEndpointStatus result
            , ownershipManifestEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

lifecycleAuthorityControllerOwnerAuthenticatedHandler
  :: (Monad m)
  => ( ControllerOwnerTransition
       -> m
            ( Either
                ControllerOwnerRepositoryError
                ControllerOwnerState
            )
     )
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityControllerOwnerAuthenticatedHandler repository inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleControllerOwner -> do
      result <-
        serveControllerOwnerEndpointRequest
          repository
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( controllerOwnerEndpointStatus result
            , controllerOwnerEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the Authority-executed recovery-plane read-back protocol.  The
-- abstract handler is constructed only inside the package-private Authority
-- boundary; this dispatch layer never sees component observations or a
-- descriptor repository provider.
lifecycleAuthorityRecoveryPlaneAuthenticatedHandler
  :: (Monad m)
  => RecoveryPlaneEndpointHandler m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityRecoveryPlaneAuthenticatedHandler handler inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleRecoveryPlane -> do
      result <-
        serveRecoveryPlaneEndpointRequest
          handler
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( recoveryPlaneEndpointStatus result
            , recoveryPlaneEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the host-only commit endpoint.  The abstract handler reloads the
-- descriptor-bound Establish attempt and commits canonical Healthy bytes;
-- this dispatch layer has no candidate constructor or repository client.
lifecycleAuthorityLocalRke2HostObservationAuthenticatedHandler
  :: (Monad m)
  => LocalRke2HostObservationEndpointHandler m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityLocalRke2HostObservationAuthenticatedHandler handler inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleLocalRke2HostObservation -> do
      result <-
        serveLocalRke2HostObservationEndpointRequest
          handler
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( localRke2HostObservationEndpointStatus result
            , localRke2HostObservationEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the closed cascade retained-slot endpoint.  The abstract handler
-- reaches exactly the three run-keyed cascade namespaces through the
-- Authority's own Model-B adapter; this dispatch layer holds no coordinate,
-- adapter, or slot bytes of its own.
lifecycleAuthorityCascadeRetainedSlotAuthenticatedHandler
  :: (Monad m)
  => CascadeRetainedSlotEndpointHandler m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityCascadeRetainedSlotAuthenticatedHandler handler inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleCascadeRetainedSlot -> do
      result <-
        serveCascadeRetainedSlotEndpointRequest
          handler
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( cascadeRetainedSlotEndpointStatus result
            , cascadeRetainedSlotEndpointBody result
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Production inputs for Authority-owned decommission export.  The
-- unprovisioned constructor is an explicit deployment state, rather than a
-- dummy repository or signer that might accidentally authorize an export.
-- Its diagnostic is retained for the composition owner; the wire response is
-- deliberately a stable non-sensitive token.
data LifecycleAuthorityDecommissionInputs m
  = LifecycleAuthorityDecommissionUnprovisioned !Text
  | LifecycleAuthorityDecommissionProvisioned
      !(AuthorityDecommissionExportRepository m)
      !(AuthorityManifestSigner m)
      !FrameDigest
      !(AuthorityDecommissionStopRepository m)

-- | Add authenticated Authority decommission export to an existing
-- role-specific handler.  Authentication and replay protection remain outside
-- this layer, so only a 'VerifiedCallerSlot' can reach the export repository.
-- Missing production inputs make readiness false and return an explicit @503@
-- without freezing admission, reading a plan, or invoking a signer.
lifecycleAuthorityDecommissionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> LifecycleAuthorityDecommissionInputs m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityDecommissionAuthenticatedHandler maximumBytes inputs inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = case inputs of
        -- An unprovisioned decommission subsystem is a dependency that has not
        -- reported, not one that is absent: it fails closed with a label rather
        -- than a bare False.
        LifecycleAuthorityDecommissionUnprovisioned _ ->
          constantRoleReadinessSource
            (unobservedRoleReadinessFacts "lifecycle-authority-decommission")
        LifecycleAuthorityDecommissionProvisioned {} ->
          authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleAuthorityDecommissionExport -> case inputs of
      LifecycleAuthorityDecommissionUnprovisioned _ ->
        pure (Just (ReplyServiceUnavailable, "authority-decommission-export-unprovisioned\n"))
      LifecycleAuthorityDecommissionProvisioned repository signer _ _ -> do
        result <-
          serveAuthorityDecommissionExportRequest
            maximumBytes
            repository
            signer
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( authorityDecommissionExportHttpStatus result
              , authorityDecommissionExportResponseBody result
              )
          )
    LifecycleAuthorityDecommissionStop -> case inputs of
      LifecycleAuthorityDecommissionUnprovisioned _ ->
        pure (Just (ReplyServiceUnavailable, "authority-decommission-stop-unprovisioned\n"))
      LifecycleAuthorityDecommissionProvisioned _ _ expectedSigner repository -> do
        result <-
          serveAuthorityDecommissionStopRequest
            maximumBytes
            expectedSigner
            repository
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( authorityDecommissionStopHttpStatus result
              , authorityDecommissionStopResponseBody result
              )
          )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the Authority-owned TLS current-reference fold to an authenticated
-- Lifecycle Authority handler.  The resolver fixes the retained coordinate
-- from the validated substrate/scope slot; no object key or CAS revision is
-- accepted over the wire.
lifecycleAuthorityTlsRetentionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityTlsRetentionAuthenticatedHandler maximumBytes resolve inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleTlsRetentionObserve -> do
      response <-
        serveTlsAuthorityObserveRequest
          maximumBytes
          resolve
          (LazyByteString.fromStrict body)
      pure (Just (tlsAuthorityResponseHttpStatus response, tlsAuthorityResponseBody response))
    LifecycleTlsRetentionPromote -> do
      response <-
        serveTlsAuthorityPromoteRequest
          maximumBytes
          resolve
          (LazyByteString.fromStrict body)
      pure (Just (tlsAuthorityResponseHttpStatus response, tlsAuthorityResponseBody response))
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the closed host trigger for the Authority-routed TLS custody workflow.
-- Target-Agent and TLS-Adapter calls are constructed by the retained Authority
-- runtime; the verified external caller can select no downstream endpoint,
-- Secret, Transit key, object key, or DEK recipient.
lifecycleAuthorityTlsRetentionWorkflowAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TlsRetentionWorkflowAuthorityBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityTlsRetentionWorkflowAuthenticatedHandler maximumBytes boundary inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    LifecycleTlsRetentionWorkflow -> do
      response <-
        serveTlsRetentionWorkflowAuthorityRequest
          maximumBytes
          boundary
          (LazyByteString.fromStrict body)
      pure
        ( Just
            ( tlsRetentionWorkflowAuthorityResponseHttpStatus response
            , tlsRetentionWorkflowAuthorityResponseBody response
            )
        )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the one Admin-Action-only Authority execution lane.  Besides the
-- closed route topology, this layer defensively requires the dedicated Runner
-- principal before constructing the caller-bound legacy checkpoint boundary.
-- The signed permit is then reverified by the endpoint with the live Authority
-- public generation before either durable state or a destination checkpoint is
-- touched.
lifecycleAuthorityAdminActionExecutionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> (VerifiedCallerSlot -> AdminActionAuthorityExecutionBoundary m)
  -> (Text -> Either Text (AdminActionEffectRepository m effectRevision))
  -> (Text -> Either Text (AdminActionAuthorityRepository m authorityRevision))
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
lifecycleAuthorityAdminActionExecutionAuthenticatedHandler
  maximumBytes
  boundaryForCaller
  resolveEffectRepository
  resolveAuthorityRepository
  inner =
    AuthenticatedRoleHandler
      { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
      , authenticatedHandlerHandle = handle
      }
   where
    handle callerSlot route body = case route of
      LifecycleAdminActionExecution
        | verifiedCallerSlotPrincipal callerSlot /= CallerAdminActionRunner ->
            pure (Just (ReplyForbidden, "admin-action-runner-caller-required\n"))
        | otherwise -> do
            response <-
              serveAdminActionAuthorityExecutionRequest
                maximumBytes
                (boundaryForCaller callerSlot)
                resolveEffectRepository
                resolveAuthorityRepository
                (LazyByteString.fromStrict body)
            pure
              ( Just
                  ( adminActionAuthorityExecutionResponseStatus response
                  , adminActionAuthorityExecutionResponseBody response
                  )
              )
      _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Build the legacy migration-only Lifecycle Authority interpreter.  The
-- caller-selected client/sequence operation endpoint is deliberately not
-- composed here; production operations exist only on the authenticated
-- aggregate handler above.
--
-- The remaining routes bind to their landed handlers over injected retained repositories:
-- @migration/apply@ → 'serveMigrationApply', @migration/import@ → the fully
-- bound 'ProjectionImportHandler', @authority/observe@ →
-- 'serveLifecycleAuthorityObserveRequest'. @maximumBytes@ bounds each request
-- body and @readiness@ is the injected cached-facts source.
lifecycleAuthorityInterpreter
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> Text
  -> m (Either Text Natural)
  -> MigrationRepository m revision
  -> ProjectionImportHandler m
  -> PulumiCheckpointHandler m
  -> RoleInterpreter m
lifecycleAuthorityInterpreter
  maximumBytes
  readiness
  authorityScope
  observeNow
  migrationRepository
  projectionImportHandler
  _pulumiCheckpointHandler =
    RoleInterpreter
      { interpreterReadiness = readiness
      , interpreterHandle = handle
      }
   where
    handle route body = case route of
      LifecycleMigrationApply -> do
        result <- serveMigrationApply maximumBytes migrationRepository (LazyByteString.fromStrict body)
        pure (Just (migrationEndpointHttpStatus result, encodeSummary (migrationEndpointSummary result)))
      LifecycleProjectionImport -> do
        result <-
          runProjectionImportHandler
            projectionImportHandler
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( projectionImportEndpointHttpStatus result
              , encodeSummary (projectionImportEndpointSummary result)
              )
          )
      LifecycleAuthorityObserve -> do
        result <-
          serveLifecycleAuthorityObserveRequest
            maximumBytes
            authorityScope
            observeNow
            migrationRepository
            (LazyByteString.fromStrict body)
        pure (Just (authorityObservationHttpStatus result, authorityObservationResponseBody result))
      _ -> pure Nothing

-- | Build the TLS Retention role's interpreter, binding both owned routes to their
-- landed handlers over the injected retention repository: @store@ →
-- 'serveTlsStoreRequest' and @restore@ → 'serveTlsRestoreRequest'. Successful
-- responses preserve the canonical binary receipt/observation; failures expose
-- only the endpoint's stable summary token.
tlsRetentionInterpreter
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> TlsRetentionRepository m
  -> RoleInterpreter m
tlsRetentionInterpreter maximumBytes readiness repository =
  RoleInterpreter
    { interpreterReadiness = readiness
    , interpreterHandle = handle
    }
 where
  handle route body = case route of
    TlsRetentionStore -> do
      result <- serveTlsStoreRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (tlsStoreHttpStatus result, tlsStoreResponseBody result))
    TlsRetentionRestore -> do
      result <- serveTlsRestoreRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (tlsRestoreHttpStatus result, tlsRestoreResponseBody result))
    _ -> pure Nothing

-- | Build the Authority Backup role's interpreter, binding both owned routes to
-- their landed opaque-byte handlers over the injected repository: @copy@ writes
-- one content-addressed ciphertext blob and confirms its bytes; @observe@ accepts
-- the exact class/digest coordinate and returns the canonical binary observation.
-- The Adapter neither decodes Authority state nor makes an admission decision.
authorityBackupInterpreter
  :: (Monad m)
  => Int
  -> RoleReadinessSource
  -> AuthorityBackupRepository m
  -> RoleInterpreter m
authorityBackupInterpreter maximumBytes readiness repository =
  RoleInterpreter
    { interpreterReadiness = readiness
    , interpreterHandle = handle
    }
 where
  handle route body = case route of
    AuthorityBackupCopy -> do
      result <- serveBackupCopyRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (authorityBackupHttpStatus result, authorityBackupCopyResponseBody result))
    AuthorityBackupObserve -> do
      result <- serveBackupObserveRequest maximumBytes repository (LazyByteString.fromStrict body)
      pure (Just (authorityBackupObserveStatus result, authorityBackupObserveResponseBody result))
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
  -> RoleReadinessSource
  -> ProviderWorkRepository m
  -> RoleInterpreter m
providerWorkerInterpreter maximumBytes readiness repository =
  RoleInterpreter
    { interpreterReadiness = readiness
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

-- | Add the exact TLS Secret lane to the authenticated Target Agent handler.
-- The lane has no coordinate input: Kubernetes namespace/name and the Transit
-- key are already fixed by the supplied production boundaries. Plaintext is
-- decoded only inside the selected Agent during seal/apply.
targetSecretAgentTlsAuthenticatedHandler
  :: Int
  -> TlsSecretBoundary IO
  -> TlsDekTransitBoundary IO
  -> AuthenticatedRoleHandler IO
  -> AuthenticatedRoleHandler IO
targetSecretAgentTlsAuthenticatedHandler maximumBytes secretBoundary transit inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    TargetTlsPrepareExchange -> do
      result <-
        serveTlsTargetPrepareRequest
          maximumBytes
          transit
          (LazyByteString.fromStrict body)
      pure (Just (tlsTargetPrepareHttpStatus result, tlsTargetPrepareResponseBody result))
    TargetTlsRetain -> do
      result <-
        serveTlsTargetRetainRequest
          maximumBytes
          secretBoundary
          (LazyByteString.fromStrict body)
      pure (Just (tlsTargetRetainHttpStatus result, tlsTargetRetainResponseBody result))
    TargetTlsHomeWrap -> do
      result <-
        serveTlsHomeWrapRequest
          maximumBytes
          transit
          (LazyByteString.fromStrict body)
      pure (Just (tlsHomeWrapHttpStatus result, tlsHomeWrapResponseBody result))
    TargetTlsHomeRewrap -> do
      result <-
        serveTlsHomeRewrapRequest
          maximumBytes
          transit
          (LazyByteString.fromStrict body)
      pure (Just (tlsHomeRewrapHttpStatus result, tlsHomeRewrapResponseBody result))
    TargetTlsRestore -> do
      result <-
        serveTlsTargetRestoreRequest
          maximumBytes
          secretBoundary
          transit
          (LazyByteString.fromStrict body)
      pure (Just (tlsTargetRestoreHttpStatus result, tlsTargetRestoreResponseBody result))
    TargetTlsVerifySource -> do
      result <-
        serveTlsTargetVerifyRequest
          maximumBytes
          secretBoundary
          (LazyByteString.fromStrict body)
      pure (Just (tlsTargetVerifyHttpStatus result, tlsTargetVerifyResponseBody result))
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Production inputs for exact Target generation tombstoning.  The pinned
-- signer digest is the trust root for the Authority manifest, and the registry
-- contains only locally owned, exact target coordinates.
data TargetSecretAgentDecommissionInputs m
  = TargetSecretAgentDecommissionUnprovisioned !Text
  | TargetSecretAgentDecommissionProvisioned
      !FrameDigest
      !(TargetGenerationTombstoneRegistry m TargetSecretPayload)
      !(TargetDecommissionInventoryBoundary m TargetSecretPayload)
      !(RetainedCustodyBoundary m)

-- | Add the authenticated tombstone route to an existing Target Secret Agent
-- handler.  An unprovisioned signer trust root or registry is represented by
-- the closed constructor above: readiness is false and the valid authenticated
-- request receives a stable @503@ before any target observation or deletion.
targetSecretAgentDecommissionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetSecretAgentDecommissionInputs m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
targetSecretAgentDecommissionAuthenticatedHandler maximumBytes inputs inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = case inputs of
        TargetSecretAgentDecommissionUnprovisioned _ ->
          constantRoleReadinessSource
            (unobservedRoleReadinessFacts "target-secret-agent-decommission")
        TargetSecretAgentDecommissionProvisioned {} ->
          authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle callerSlot route body = case route of
    TargetSecretDecommissionTombstone -> case inputs of
      TargetSecretAgentDecommissionUnprovisioned _ ->
        pure (Just (ReplyServiceUnavailable, "target-generation-tombstone-unprovisioned\n"))
      TargetSecretAgentDecommissionProvisioned expectedSigner registry _ _ -> do
        result <-
          serveTargetGenerationTombstoneRequest
            maximumBytes
            expectedSigner
            registry
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( targetGenerationTombstoneHttpStatus result
              , targetGenerationTombstoneResponseBody result
              )
          )
    TargetSecretDecommissionInventory -> case inputs of
      TargetSecretAgentDecommissionUnprovisioned _ ->
        pure (Just (ReplyServiceUnavailable, "target-decommission-inventory-unprovisioned\n"))
      TargetSecretAgentDecommissionProvisioned _ _ boundary _ -> do
        result <-
          serveTargetDecommissionInventoryRequest
            maximumBytes
            boundary
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( targetDecommissionInventoryHttpStatus result
              , targetDecommissionInventoryResponseBody result
              )
          )
    TargetSecretDecommissionCustodyTombstone -> case inputs of
      TargetSecretAgentDecommissionUnprovisioned _ ->
        pure (Just (ReplyServiceUnavailable, "retained-custody-tombstone-unprovisioned\n"))
      TargetSecretAgentDecommissionProvisioned expectedSigner _ _ boundary -> do
        result <-
          serveRetainedCustodyTombstoneRequest
            maximumBytes
            expectedSigner
            boundary
            (LazyByteString.fromStrict body)
        pure
          ( Just
              ( retainedCustodyTombstoneHttpStatus result
              , retainedCustodyTombstoneResponseBody result
              )
          )
    _ -> authenticatedHandlerHandle inner callerSlot route body

-- | Add the two Admin-Action-only Target tombstone lanes.  Unlike the
-- decommission routes above, these verify the complete backup-bound and
-- Pod-bound Admin Action permit with the live Authority Transit public key.
-- The verified caller must also be the dedicated Runner principal; operator,
-- harness, Authority, and every standing service are refused even if a trust
-- registry is accidentally widened.
targetSecretAgentAdminActionAuthenticatedHandler
  :: (Monad m)
  => Int
  -> AuthorityManifestSigner m
  -> m (Either Text AuthorityTime)
  -> Text
  -> TargetGenerationTombstoneRegistry m TargetSecretPayload
  -> RetainedCustodyBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
targetSecretAgentAdminActionAuthenticatedHandler
  maximumBytes
  signer
  now
  localIdentity
  registry
  custody
  inner =
    AuthenticatedRoleHandler
      { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
      , authenticatedHandlerHandle = handle
      }
   where
    verification =
      AdminActionTargetVerification
        { adminTargetAuthoritySigner = signer
        , adminTargetCurrentTime = now
        , adminTargetLocalIdentity = localIdentity
        }
    handle callerSlot route body
      | route `elem` adminRoutes
          && verifiedCallerSlotPrincipal callerSlot /= CallerAdminActionRunner =
          pure (Just (ReplyForbidden, "admin-action-runner-caller-required\n"))
      | otherwise = case route of
          TargetSecretAdminActionGenerationTombstone -> do
            response <-
              serveAdminTargetTombstoneRequest
                maximumBytes
                verification
                registry
                (LazyByteString.fromStrict body)
            pure
              ( Just
                  ( adminTargetTombstoneResponseStatus response
                  , adminActionTargetResponseBody response
                  )
              )
          TargetSecretAdminActionCustodyTombstone -> do
            response <-
              serveAdminCustodyTombstoneRequest
                maximumBytes
                verification
                custody
                (LazyByteString.fromStrict body)
            pure
              ( Just
                  ( adminCustodyTombstoneResponseStatus response
                  , adminActionTargetResponseBody response
                  )
              )
          _ -> authenticatedHandlerHandle inner callerSlot route body
    adminRoutes =
      [ TargetSecretAdminActionGenerationTombstone
      , TargetSecretAdminActionCustodyTombstone
      ]

encodeSummary :: Text -> ByteString
encodeSummary = TextEncoding.encodeUtf8
