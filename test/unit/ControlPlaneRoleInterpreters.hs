{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRoleInterpreters (controlPlaneRoleInterpretersSuite) where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (fromJust)
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupRepository
      ( AuthorityBackupRepository
      , commitAdmissionState
      , readAdmissionState
      )
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.OperationEndpoint
  ( OperationObservePayload (OperationObservePayload)
  , OperationSubmissionRepository
    ( OperationSubmissionRepository
    , commitSubmissionLedger
    , readSubmissionState
    )
  , OperationSubmitPayload (OperationSubmitPayload)
  )
import Prodbox.ControlPlane.ProviderWorkEndpoint
  ( ProviderIntentKind (ReconcileStackIntent)
  , ProviderWorkApplyPayload (ProviderWorkApplyPayload)
  , ProviderWorkCommandKind (SubmitCommand)
  , ProviderWorkRepository
    ( ProviderWorkRepository
    , commitProviderWorkState
    , readBoundProviderRevision
    , readProviderAuthorityNow
    , readProviderSessionDeadline
    , readProviderWorkState
    , readRegisteredProviderResources
    )
  , applyCommandKind
  , applyCoordinate
  , applyIntentKind
  , applyRequestedRevision
  , applyResourceRef
  )
import Prodbox.ControlPlane.RoleInterpreters
  ( authorityBackupInterpreter
  , lifecycleAuthorityInterpreter
  , providerWorkerInterpreter
  , tlsRetentionInterpreter
  )
import Prodbox.ControlPlane.Server (RoleInterpreter, serveControlPlaneRequest)
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsRetentionRepository (TlsRetentionRepository, commitRetainedRef, readRetentionState)
  , TlsStorePayload (TlsStorePayload)
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (BackupPositivelyAbsent)
  , BackupRepairCommand (AssessBackupHealth)
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (BackupEstablished)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCommand (RequestLegacyRollback, VerifyShadow)
  , encodeMigrationCommand
  , mkMigrationDigest
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (MigrationRepository, compareAndSwapMigrationState, readMigrationState)
  , StoredMigration (StoredMigration, storedMigrationRevision)
  )
import Prodbox.Lifecycle.Authority.Submission (SubmissionLedger, emptySubmissionLedger)
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (CertIdentity)
  , KeyRotationApproval (KeyRotationNotApproved)
  , PromotionEvidence (PromotionEvidence)
  , RestoreObservation (RestoreCommittedIntact)
  , RetainedTlsRef (RetainedTlsRef)
  , RetentionVersion (RetentionVersion)
  , SourceSecretRef (SourceSecretRef)
  , TlsRetentionState (TlsRetentionCurrent)
  , initialTlsRetentionState
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderWorkState (ProviderIdle)
  , mkProviderRevision
  , mkRegisteredProviderResources
  )
import Prodbox.Runtime.Role
  ( RuntimeRole
      ( AuthorityBackupRuntime
      , LifecycleAuthorityRuntime
      , ProviderWorkerRuntime
      , TlsRetentionRuntime
      )
  )
import TestSupport

controlPlaneRoleInterpretersSuite :: SuiteBuilder ()
controlPlaneRoleInterpretersSuite =
  describe "Sprint 4.50 control-plane role interpreter builders" $ do
    describe "Lifecycle Authority interpreter (migration + operations through the seam)" $ do
      it "serves liveness and the injected readiness probe" $ do
        ready <- freshLifecycleInterpreter True
        serveLA ready "GET /healthz HTTP/1.1\r\n\r\n" `shouldReturn` (200, "live\n")
        serveLA ready "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (200, "ready\n")
        notReady <- freshLifecycleInterpreter False
        serveLA notReady "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (503, "not-ready\n")
      it "dispatches migration accept and refuse to the migration handler" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (post "/v1/migration/apply" (migrationBody (VerifyShadow digest)))
          `shouldReturn` (200, "migration-accepted")
        serveLA interpreter (post "/v1/migration/apply" (migrationBody RequestLegacyRollback))
          `shouldReturn` (409, "migration-refused:legacy-rollback-forbidden")
      it "dispatches an operation submit and its idempotent duplicate to the submit handler" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (post "/v1/operations/submit" (encoded (OperationSubmitPayload "c1" 1 "dA")))
          `shouldReturn` (200, "operation-accepted")
        serveLA interpreter (post "/v1/operations/submit" (encoded (OperationSubmitPayload "c1" 1 "dA")))
          `shouldReturn` (200, "operation-duplicate")
      it "dispatches a GET-with-body observe to the observe handler after a submit" $ do
        interpreter <- freshLifecycleInterpreter True
        _ <-
          serveLA interpreter (post "/v1/operations/submit" (encoded (OperationSubmitPayload "c1" 1 "dA")))
        serveLA interpreter (get "/v1/operations/observe" (encoded (OperationObservePayload "c1" 1)))
          `shouldReturn` (200, "operation-in-flight")
      it "observes a never-submitted operation as 404 unknown through the seam" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (get "/v1/operations/observe" (encoded (OperationObservePayload "c1" 1)))
          `shouldReturn` (404, "operation-unknown")
      it "maps a malformed observe body to a 400 bad request through the seam" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (get "/v1/operations/observe" "not-a-cbor-envelope")
          `shouldReturn` (400, "operation-observe-bad-request:invalid")
      it "refuses a route owned by a different role with 404 route-not-owned" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (post "/v1/tls-retention/store" "body")
          `shouldReturn` (404, "route-not-owned\n")
    describe "TLS Retention interpreter (store + restore through the seam)" $ do
      it "dispatches a well-formed store to the store handler and promotes" $ do
        interpreter <- freshTlsInterpreter initialTlsRetentionState True
        serveTls
          interpreter
          (post "/v1/tls-retention/store" (encoded (TlsStorePayload KeyRotationNotApproved goodEvidence ref1)))
          `shouldReturn` (200, "tls-promoted")
      it "dispatches a well-formed restore to the restore handler and applies it" $ do
        interpreter <- freshTlsInterpreter (TlsRetentionCurrent ref1) True
        serveTls interpreter (post "/v1/tls-retention/restore" (encoded (RestoreCommittedIntact ref1)))
          `shouldReturn` (200, "tls-restore-apply")
      it "maps a malformed store body to a 400 bad request through the seam" $ do
        interpreter <- freshTlsInterpreter initialTlsRetentionState True
        serveTls interpreter (post "/v1/tls-retention/store" "not-a-cbor-envelope")
          `shouldReturn` (400, "tls-bad-request:invalid")
      it "serves the injected readiness probe" $ do
        notReady <- freshTlsInterpreter initialTlsRetentionState False
        serveTls notReady "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (503, "not-ready\n")
    describe "Authority Backup interpreter (copy + observe through the seam)" $ do
      it "dispatches a copy that freezes admission to the copy handler" $ do
        interpreter <- freshBackupInterpreter established1 True
        serveBackup
          interpreter
          (post "/v1/authority-backup/copy" (encoded (AssessBackupHealth BackupPositivelyAbsent)))
          `shouldReturn` (200, "backup-froze")
      it "observes the current admission state through the seam" $ do
        interpreter <- freshBackupInterpreter established1 True
        serveBackup interpreter (get "/v1/authority-backup/observe" "")
          `shouldReturn` (200, "backup-observe:established")
      it "reflects a committed freeze in a later observe through the seam" $ do
        interpreter <- freshBackupInterpreter established1 True
        _ <-
          serveBackup
            interpreter
            (post "/v1/authority-backup/copy" (encoded (AssessBackupHealth BackupPositivelyAbsent)))
        serveBackup interpreter (get "/v1/authority-backup/observe" "")
          `shouldReturn` (200, "backup-observe:repair-frozen")
      it "maps a malformed copy body to a 400 bad request through the seam" $ do
        interpreter <- freshBackupInterpreter established1 True
        serveBackup interpreter (post "/v1/authority-backup/copy" "not-a-cbor-envelope")
          `shouldReturn` (400, "backup-bad-request:invalid")
      it "refuses a route owned by a different role with 404 route-not-owned" $ do
        interpreter <- freshBackupInterpreter established1 True
        serveBackup interpreter (post "/v1/tls-retention/store" "body")
          `shouldReturn` (404, "route-not-owned\n")
      it "serves the injected readiness probe" $ do
        notReady <- freshBackupInterpreter established1 False
        serveBackup notReady "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (503, "not-ready\n")
    describe "Provider Worker interpreter (apply + observe through the seam)" $ do
      it "dispatches a well-formed stack reconcile to the apply handler and admits it" $ do
        interpreter <- freshProviderInterpreter ProviderIdle True
        serveProvider interpreter (post "/v1/provider-work/apply" (encoded submitReconcile))
          `shouldReturn` (200, "provider-work-admitted")
      it "observes the idle session through the seam" $ do
        interpreter <- freshProviderInterpreter ProviderIdle True
        serveProvider interpreter (get "/v1/provider-work/observe" "")
          `shouldReturn` (200, "provider-work-observe:idle")
      it "refuses an unregistered resource with a 409 through the seam" $ do
        interpreter <- freshProviderInterpreter ProviderIdle True
        serveProvider interpreter (post "/v1/provider-work/apply" (encoded submitStaging))
          `shouldReturn` (409, "provider-work-refused:unregistered-resource")
      it "maps a malformed apply body to a 400 bad request through the seam" $ do
        interpreter <- freshProviderInterpreter ProviderIdle True
        serveProvider interpreter (post "/v1/provider-work/apply" "not-a-cbor-envelope")
          `shouldReturn` (400, "provider-work-bad-request:invalid")
      it "refuses a route owned by a different role with 404 route-not-owned" $ do
        interpreter <- freshProviderInterpreter ProviderIdle True
        serveProvider interpreter (post "/v1/tls-retention/store" "body")
          `shouldReturn` (404, "route-not-owned\n")
      it "serves the injected readiness probe" $ do
        notReady <- freshProviderInterpreter ProviderIdle False
        serveProvider notReady "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (503, "not-ready\n")
 where
  digest = fromJust (mkMigrationDigest "interpreter-v1")
  goodEvidence = PromotionEvidence True True
  src = SourceSecretRef "uid-1" "rv-1"
  ref1 = RetainedTlsRef (RetentionVersion 1) (CertIdentity "serial-1" "spki-A" 1000) "ct-1" src
  established1 = BackupEstablished authorityEpochGenesis
  serveLA interpreter request = serveControlPlaneRequest interpreter LifecycleAuthorityRuntime request
  serveTls interpreter request = serveControlPlaneRequest interpreter TlsRetentionRuntime request
  serveBackup interpreter request = serveControlPlaneRequest interpreter AuthorityBackupRuntime request
  serveProvider interpreter request = serveControlPlaneRequest interpreter ProviderWorkerRuntime request
  submitReconcile =
    ProviderWorkApplyPayload
      { applyCommandKind = SubmitCommand
      , applyIntentKind = ReconcileStackIntent
      , applyResourceRef = "prod"
      , applyRequestedRevision = 3
      , applyCoordinate = ""
      }
  submitStaging = submitReconcile {applyResourceRef = "staging"}

freshLifecycleInterpreter :: Bool -> IO (RoleInterpreter IO)
freshLifecycleInterpreter ready = do
  migrationRepository <- freshMigrationRepository
  submissionRepository <- freshSubmissionRepository 4
  pure (lifecycleAuthorityInterpreter 4096 (pure ready) migrationRepository submissionRepository)

freshTlsInterpreter :: TlsRetentionState -> Bool -> IO (RoleInterpreter IO)
freshTlsInterpreter initial ready = do
  stateRef <- newIORef initial
  let repository =
        TlsRetentionRepository
          { readRetentionState = readIORef stateRef
          , commitRetainedRef = \ref -> do
              writeIORef stateRef (TlsRetentionCurrent ref)
              pure (Right ())
          }
  pure (tlsRetentionInterpreter 4096 (pure ready) repository)

freshBackupInterpreter :: AuthorityAdmissionState -> Bool -> IO (RoleInterpreter IO)
freshBackupInterpreter initial ready = do
  stateRef <- newIORef initial
  let repository =
        AuthorityBackupRepository
          { readAdmissionState = readIORef stateRef
          , commitAdmissionState = \state -> do
              writeIORef stateRef state
              pure (Right ())
          }
  pure (authorityBackupInterpreter 4096 (pure ready) repository)

freshProviderInterpreter :: ProviderWorkState -> Bool -> IO (RoleInterpreter IO)
freshProviderInterpreter initial ready = do
  stateRef <- newIORef initial
  let repository =
        ProviderWorkRepository
          { readProviderWorkState = readIORef stateRef
          , readRegisteredProviderResources =
              pure (mkRegisteredProviderResources ["stack:prod", "ses-identity:mail"])
          , readBoundProviderRevision = pure (either (error . show) id (mkProviderRevision 2))
          , readProviderAuthorityNow = pure (authorityTimeFromMicros 1000)
          , readProviderSessionDeadline = pure (authorityTimeFromMicros 5000)
          , commitProviderWorkState = \state -> do
              writeIORef stateRef state
              pure (Right ())
          }
  pure (providerWorkerInterpreter 4096 (pure ready) repository)

freshSubmissionRepository :: Word -> IO (OperationSubmissionRepository IO)
freshSubmissionRepository capacity = do
  ledgerRef <- newIORef (emptySubmissionLedger (fromIntegral capacity) :: SubmissionLedger)
  pure
    OperationSubmissionRepository
      { readSubmissionState = do
          ledger <- readIORef ledgerRef
          pure (authorityEpochGenesis, ledger)
      , commitSubmissionLedger = \ledger -> do
          writeIORef ledgerRef ledger
          pure (Right ())
      }

freshMigrationRepository :: IO (MigrationRepository IO Word)
freshMigrationRepository = do
  stateRef <- newIORef Nothing
  revisionRef <- newIORef (0 :: Word)
  pure
    MigrationRepository
      { readMigrationState = Right <$> readIORef stateRef
      , compareAndSwapMigrationState = \expected bytes -> do
          observed <- readIORef stateRef
          if (storedMigrationRevision <$> observed) /= expected
            then pure (Right False)
            else do
              next <- atomicModifyIORef' revisionRef (\value -> (value + 1, value + 1))
              writeIORef stateRef (Just (StoredMigration next bytes))
              pure (Right True)
      }

post :: ByteString -> ByteString -> ByteString
post path body = "POST " <> path <> " HTTP/1.1\r\n\r\n" <> body

get :: ByteString -> ByteString -> ByteString
get path body = "GET " <> path <> " HTTP/1.1\r\n\r\n" <> body

-- | Frame any control-plane request payload as the strict request bytes the seam
-- receives: the shared bounded/versioned/canonical envelope, then strict.
encoded :: (Serialise a) => a -> ByteString
encoded = LazyByteString.toStrict . encodeControlPlaneRequest

migrationBody :: MigrationCommand -> ByteString
migrationBody = LazyByteString.toStrict . encodeMigrationCommand
