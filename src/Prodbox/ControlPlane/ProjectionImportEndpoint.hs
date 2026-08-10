{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed Lifecycle Authority endpoint for importing legacy projections.
--
-- The wire request can select one member of the finite projection inventory or
-- request completion.  It carries no bytes, digest, revision, evidence, or
-- object coordinate.  Those values are observed and derived inside the
-- Authority through 'importLegacyProjection', so a caller cannot smuggle a
-- fabricated import into the durable migration state.
module Prodbox.ControlPlane.ProjectionImportEndpoint
  ( ProjectionImportRequest (..)
  , ProjectionImportEndpointResult (..)
  , ProjectionImportHandler
  , mkProjectionImportHandlerWithApplicator
  , mkProjectionImportHandler
  , resolvingProjectionImportHandler
  , unavailableProjectionImportHandler
  , runProjectionImportHandler
  , encodeProjectionImportRequest
  , serveProjectionImportRequestWithApplicator
  , serveProjectionImportRequest
  , projectionImportEndpointHttpStatus
  , projectionImportEndpointSummary
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommandRefusal (..)
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationImportDecision (..)
  , MigrationImportRefusal (..)
  , MigrationProjection
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationApplyError (..)
  , MigrationImportApplyResult (..)
  , MigrationRepository
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( LegacyProjectionSource
  , MigrationImportApplicationError (..)
  , MigrationImportCommandApplicator
  , ProjectionImportCodecConfig
  , ProjectionImportFailure (..)
  , ProjectionImportResult (..)
  , ProjectionImportTarget
  , completeVerifiedProjectionImportsWithApplicator
  , importLegacyProjectionWithApplicator
  , migrationRepositoryImportApplicator
  )

data ProjectionImportRequest
  = ImportLegacyProjection !MigrationProjection
  | CompleteLegacyProjectionImports
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProjectionImportEndpointResult
  = ProjectionImportEndpointBadRequest !ControlPlaneRequestCodecError
  | ProjectionImportEndpointImported
      !MigrationProjection
      !ProjectionImportResult
  | ProjectionImportEndpointCompleted !MigrationImportApplyResult
  | ProjectionImportEndpointImportFailed !ProjectionImportFailure
  | ProjectionImportEndpointStateFailed !MigrationImportApplicationError
  deriving stock (Eq, Show)

encodeProjectionImportRequest :: ProjectionImportRequest -> ByteString
encodeProjectionImportRequest = encodeControlPlaneRequest

-- | Fully bound import endpoint for installation in the Lifecycle Authority
-- role interpreter.  The source/target revision types remain hidden at the
-- dispatch layer; only startup composition can supply the typed adapters and
-- exact coordinate inventory used by the smart constructor below.
newtype ProjectionImportHandler m = ProjectionImportHandler
  { runProjectionImportHandler
      :: ByteString
      -> m ProjectionImportEndpointResult
  }

-- | Production constructor.  Evidence is committed through the injected
-- closed command applicator, which is backed by the single Authority admission
-- aggregate in the Lifecycle Authority runtime.
mkProjectionImportHandlerWithApplicator
  :: (Monad m, Eq sourceRevision)
  => Int
  -> ProjectionImportCodecConfig
  -> MigrationImportCommandApplicator m
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> ProjectionImportHandler m
mkProjectionImportHandlerWithApplicator
  requestMaximum
  config
  applicator
  source
  target =
    ProjectionImportHandler
      ( serveProjectionImportRequestWithApplicator
          requestMaximum
          config
          applicator
          source
          target
      )

-- | Compatibility constructor for fixtures that retain the historical
-- standalone migration repository.
mkProjectionImportHandler
  :: (Monad m, Eq sourceRevision)
  => Int
  -> Int
  -> ProjectionImportCodecConfig
  -> MigrationRepository m migrationRevision
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> ProjectionImportHandler m
mkProjectionImportHandler
  requestMaximum
  migrationMaximum
  config
  repository
  source
  target =
    mkProjectionImportHandlerWithApplicator
      requestMaximum
      config
      (migrationRepositoryImportApplicator migrationMaximum repository)
      source
      target

-- | Fail-closed binding used only while startup composition cannot supply the
-- exact legacy projection identity and source/target transports.  Keeping this
-- as an explicit handler means the closed route remains total without
-- inventing coordinates or accepting caller-supplied object names.
unavailableProjectionImportHandler :: (Applicative m) => Text -> ProjectionImportHandler m
unavailableProjectionImportHandler detail =
  ProjectionImportHandler
    ( const
        ( pure
            ( ProjectionImportEndpointStateFailed
                (MigrationImportAuthorityReadFailed detail)
            )
        )
    )

-- | Resolve the exact production import binding for each request.  The
-- registration is retained authority state and may appear after the process
-- starts; resolving here lets a missing registration fail closed without
-- requiring a restart once a trusted provisioner commits it.  Resolution
-- failure is deliberately projected as an unavailable state read, never as an
-- empty legacy inventory.
resolvingProjectionImportHandler
  :: (Monad m)
  => m (Either Text (ProjectionImportHandler m))
  -> ProjectionImportHandler m
resolvingProjectionImportHandler resolve =
  ProjectionImportHandler $ \body -> do
    resolved <- resolve
    case resolved of
      Left detail ->
        pure
          ( ProjectionImportEndpointStateFailed
              (MigrationImportAuthorityReadFailed detail)
          )
      Right handler -> runProjectionImportHandler handler body

serveProjectionImportRequest
  :: (Monad m, Eq sourceRevision)
  => Int
  -> Int
  -> ProjectionImportCodecConfig
  -> MigrationRepository m migrationRevision
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> ByteString
  -> m ProjectionImportEndpointResult
serveProjectionImportRequest requestMaximum migrationMaximum config repository source target body =
  serveProjectionImportRequestWithApplicator
    requestMaximum
    config
    (migrationRepositoryImportApplicator migrationMaximum repository)
    source
    target
    body

serveProjectionImportRequestWithApplicator
  :: (Monad m, Eq sourceRevision)
  => Int
  -> ProjectionImportCodecConfig
  -> MigrationImportCommandApplicator m
  -> LegacyProjectionSource m sourceRevision
  -> ProjectionImportTarget m targetRevision
  -> ByteString
  -> m ProjectionImportEndpointResult
serveProjectionImportRequestWithApplicator requestMaximum config applicator source target body =
  case decodeControlPlaneRequest requestMaximum body of
    Left err -> pure (ProjectionImportEndpointBadRequest err)
    Right request -> case request of
      ImportLegacyProjection projection -> do
        imported <-
          importLegacyProjectionWithApplicator
            config
            applicator
            source
            target
            projection
        pure $ case imported of
          Left failure -> ProjectionImportEndpointImportFailed failure
          Right result -> ProjectionImportEndpointImported projection result
      CompleteLegacyProjectionImports -> do
        completed <- completeVerifiedProjectionImportsWithApplicator applicator
        pure $ case completed of
          Left failure -> ProjectionImportEndpointStateFailed failure
          Right result -> ProjectionImportEndpointCompleted result

projectionImportEndpointHttpStatus :: ProjectionImportEndpointResult -> ReplyStatus
projectionImportEndpointHttpStatus result = case result of
  ProjectionImportEndpointBadRequest _ -> ReplyBadRequest
  ProjectionImportEndpointImported _ imported ->
    importDecisionStatus
      (appliedMigrationImportDecision (projectionImportStateResult imported))
  ProjectionImportEndpointCompleted completed ->
    importDecisionStatus (appliedMigrationImportDecision completed)
  ProjectionImportEndpointImportFailed failure -> importFailureStatus failure
  ProjectionImportEndpointStateFailed failure -> migrationFailureStatus failure

projectionImportEndpointSummary :: ProjectionImportEndpointResult -> Text
projectionImportEndpointSummary result = case result of
  ProjectionImportEndpointBadRequest err ->
    "projection-import-bad-request:" <> controlPlaneRequestCodecToken err
  ProjectionImportEndpointImported _ imported ->
    importDecisionSummary
      (appliedMigrationImportDecision (projectionImportStateResult imported))
  ProjectionImportEndpointCompleted completed ->
    "projection-imports-" <> importDecisionToken (appliedMigrationImportDecision completed)
  ProjectionImportEndpointImportFailed failure -> importFailureSummary failure
  ProjectionImportEndpointStateFailed failure -> migrationFailureSummary failure

importDecisionStatus :: MigrationImportDecision -> ReplyStatus
importDecisionStatus decision = case decision of
  MigrationImportAccepted -> ReplyOk
  MigrationImportAlreadyApplied -> ReplyOk
  MigrationImportRefused _ -> ReplyConflict

importDecisionSummary :: MigrationImportDecision -> Text
importDecisionSummary decision =
  "projection-import-" <> importDecisionToken decision

importDecisionToken :: MigrationImportDecision -> Text
importDecisionToken decision = case decision of
  MigrationImportAccepted -> "accepted"
  MigrationImportAlreadyApplied -> "already-applied"
  MigrationImportRefused refusal -> "refused:" <> importRefusalToken refusal

importRefusalToken :: MigrationImportRefusal -> Text
importRefusalToken refusal = case refusal of
  MigrationImportClosed -> "closed"
  MigrationImportConflict _ -> "conflict"
  MigrationImportsMissing _ -> "imports-missing"

importFailureStatus :: ProjectionImportFailure -> ReplyStatus
importFailureStatus failure = case failure of
  ProjectionImportSourceCorrupt {} -> ReplyInternalError
  ProjectionImportSourceCodecCorrupt {} -> ReplyInternalError
  ProjectionImportSourceEndpointUnready {} -> ReplyServiceUnavailable
  ProjectionImportSourceUnobservable {} -> ReplyServiceUnavailable
  ProjectionImportSourceChanged {} -> ReplyConflict
  ProjectionImportShadowChanged {} -> ReplyConflict
  ProjectionImportTargetCorrupt {} -> ReplyInternalError
  ProjectionImportTargetCodecCorrupt {} -> ReplyInternalError
  ProjectionImportTargetEndpointUnready {} -> ReplyServiceUnavailable
  ProjectionImportTargetUnobservable {} -> ReplyServiceUnavailable
  ProjectionImportTargetConflict {} -> ReplyConflict
  ProjectionImportTargetUnexpectedPresent {} -> ReplyConflict
  ProjectionImportTargetReadbackMissing {} -> ReplyConflict
  ProjectionImportTargetWriteRefused {} -> ReplyInternalError
  ProjectionImportMigrationStateFailed migrationFailure ->
    migrationFailureStatus migrationFailure

importFailureSummary :: ProjectionImportFailure -> Text
importFailureSummary failure = case failure of
  ProjectionImportSourceCorrupt {} -> "projection-import-source-corrupt"
  ProjectionImportSourceCodecCorrupt {} -> "projection-import-source-codec-corrupt"
  ProjectionImportSourceEndpointUnready {} -> "projection-import-source-endpoint-unready"
  ProjectionImportSourceUnobservable {} -> "projection-import-source-unobservable"
  ProjectionImportSourceChanged {} -> "projection-import-source-changed"
  ProjectionImportShadowChanged {} -> "projection-import-shadow-changed"
  ProjectionImportTargetCorrupt {} -> "projection-import-target-corrupt"
  ProjectionImportTargetCodecCorrupt {} -> "projection-import-target-codec-corrupt"
  ProjectionImportTargetEndpointUnready {} -> "projection-import-target-endpoint-unready"
  ProjectionImportTargetUnobservable {} -> "projection-import-target-unobservable"
  ProjectionImportTargetConflict {} -> "projection-import-target-conflict"
  ProjectionImportTargetUnexpectedPresent {} -> "projection-import-target-unexpected-present"
  ProjectionImportTargetReadbackMissing {} -> "projection-import-target-readback-missing"
  ProjectionImportTargetWriteRefused {} -> "projection-import-target-write-refused"
  ProjectionImportMigrationStateFailed migrationFailure ->
    migrationFailureSummary migrationFailure

migrationFailureStatus :: MigrationImportApplicationError -> ReplyStatus
migrationFailureStatus failure = case failure of
  MigrationImportCompatibilityRepositoryFailed compatibilityFailure ->
    compatibilityFailureStatus compatibilityFailure
  MigrationImportAuthorityReadFailed _ -> ReplyServiceUnavailable
  MigrationImportAuthorityWriteFailed _ -> ReplyServiceUnavailable
  MigrationImportAuthorityReadbackFailed _ -> ReplyServiceUnavailable
  MigrationImportAuthorityRefused refusal -> authorityRefusalStatus refusal
  MigrationImportAuthorityProtocolViolation _ -> ReplyInternalError
  MigrationImportAuthorityReadbackDiverged {} -> ReplyConflict

migrationFailureSummary :: MigrationImportApplicationError -> Text
migrationFailureSummary failure = case failure of
  MigrationImportCompatibilityRepositoryFailed compatibilityFailure ->
    compatibilityFailureSummary compatibilityFailure
  MigrationImportAuthorityReadFailed _ -> "projection-import-authority-read-failed"
  MigrationImportAuthorityWriteFailed _ -> "projection-import-authority-write-failed"
  MigrationImportAuthorityReadbackFailed _ ->
    "projection-import-authority-readback-failed"
  MigrationImportAuthorityRefused refusal ->
    "projection-import-authority-refused:" <> authorityRefusalToken refusal
  MigrationImportAuthorityProtocolViolation _ ->
    "projection-import-authority-protocol-violation"
  MigrationImportAuthorityReadbackDiverged {} ->
    "projection-import-authority-readback-diverged"

compatibilityFailureStatus :: MigrationApplyError -> ReplyStatus
compatibilityFailureStatus failure = case failure of
  MigrationReadFailed _ -> ReplyServiceUnavailable
  MigrationDecodeFailed _ -> ReplyInternalError
  MigrationWriteFailed _ -> ReplyServiceUnavailable
  MigrationConcurrentWrite -> ReplyConflict

compatibilityFailureSummary :: MigrationApplyError -> Text
compatibilityFailureSummary failure = case failure of
  MigrationReadFailed _ -> "projection-import-state-read-failed"
  MigrationDecodeFailed _ -> "projection-import-state-corrupt"
  MigrationWriteFailed _ -> "projection-import-state-write-failed"
  MigrationConcurrentWrite -> "projection-import-state-concurrent-write"

authorityRefusalStatus :: AuthorityAdmissionCommandRefusal -> ReplyStatus
authorityRefusalStatus refusal = case refusal of
  AuthorityMigrationBeforeGenesis -> ReplyServiceUnavailable
  AuthorityMigrationDuringBackupRepair -> ReplyServiceUnavailable
  AuthorityMigrationAlreadyStarted -> ReplyConflict
  AuthorityMigrationNotStarted -> ReplyConflict
  AuthorityMigrationEpochRegressed {} -> ReplyConflict

authorityRefusalToken :: AuthorityAdmissionCommandRefusal -> Text
authorityRefusalToken refusal = case refusal of
  AuthorityMigrationBeforeGenesis -> "before-genesis"
  AuthorityMigrationDuringBackupRepair -> "during-backup-repair"
  AuthorityMigrationAlreadyStarted -> "already-started"
  AuthorityMigrationNotStarted -> "not-started"
  AuthorityMigrationEpochRegressed {} -> "epoch-regressed"
