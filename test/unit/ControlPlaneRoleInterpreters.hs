{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRoleInterpreters (controlPlaneRoleInterpretersSuite) where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (fromJust)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (AuthorityAdmissionSnapshot)
  , AuthorityControlPayload (AuthorityControlBeginMigration)
  , AuthorityOperationSubmitPayload (AuthorityOperationSubmitPayload)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityAggregateEnvelope)
  , AuthorityBackupBlobObservation (AuthorityBackupBlobMissing, AuthorityBackupBlobPresent)
  , AuthorityBackupCopyRequest (AuthorityBackupCopyRequest)
  , AuthorityBackupObserveRequest (AuthorityBackupObserveRequest)
  , AuthorityBackupReceipt (..)
  , AuthorityBackupRepository (..)
  , authorityBackupCiphertextDigest
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.ProjectionImportEndpoint
  ( ProjectionImportRequest (ImportLegacyProjection)
  , encodeProjectionImportRequest
  , mkProjectionImportHandler
  , unavailableProjectionImportHandler
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
  , applySecondaryRef
  , applyStackConfig
  , applyTertiaryRef
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointHandler
  , PulumiCheckpointObservation (PulumiCheckpointMissing)
  , PulumiCheckpointPublicationResult (PulumiCheckpointPublicationUnavailable)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointRequest (ObservePulumiCheckpoint)
  , PulumiCheckpointRetirementResult (PulumiCheckpointRetirementUnavailable)
  , mkPulumiCheckpointHandler
  )
import Prodbox.ControlPlane.RetainedSesLeaseEndpoint
  ( RetainedSesLeaseRequest (ObserveRetainedSesLease)
  , RetainedSesLeaseResponse (RetainedSesLeaseUnavailable)
  , resolvingRetainedSesLeaseHandler
  )
import Prodbox.ControlPlane.RoleInterpreters
  ( authorityBackupInterpreter
  , lifecycleAuthorityAdmissionInterpreter
  , lifecycleAuthorityInterpreter
  , providerWorkerInterpreter
  , tlsRetentionInterpreter
  )
import Prodbox.ControlPlane.Server (RoleInterpreter, serveControlPlaneRequest)
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (TlsEnvelopeMissing, TlsEnvelopePresent)
  , TlsRestorePayload (TlsRestorePayload)
  , TlsRetentionReceipt (..)
  , TlsRetentionRepository (..)
  , TlsSealedEnvelope
  , TlsStorePayload (TlsStorePayload)
  , mkTlsSealedEnvelope
  , tlsSealedEnvelopeDigest
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , initialCleanInstallAuthority
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand
      ( BeginGenesisEstablishment
      , ObserveBackupReceipt
      , ObserveTargetAgentGeneration
      )
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (GenesisPlan)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCommand (RequestLegacyRollback, VerifyShadow)
  , MigrationProjection (CheckpointProjection)
  , encodeMigrationCommand
  , mkMigrationDigest
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (MigrationRepository, compareAndSwapMigrationState, readMigrationState)
  , StoredMigration (StoredMigration, storedMigrationRevision)
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( LegacyProjectionObservation (LegacyProjectionMissing)
  , LegacyProjectionSource (LegacyProjectionSource)
  , ProjectionImportTarget (..)
  , ProjectionTargetObservation (ProjectionTargetMissing)
  , ProjectionTargetWriteResult (ProjectionTargetWriteUnobservable)
  , mkProjectionImportCodecConfig
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (CertIdentity)
  , RetainedTlsRef (RetainedTlsRef)
  , RetentionVersion (RetentionVersion)
  , SourceSecretRef (SourceSecretRef)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , defaultSesLeasePolicy
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderWorkState (ProviderIdle)
  , mkAwsEksProviderStackConfig
  , mkProviderRevision
  , mkRegisteredProviderResources
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkRegisteredTargetSet
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
      it "dispatches a closed projection import to the verified import handler" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA
          interpreter
          ( post
              "/v1/migration/import"
              ( LazyByteString.toStrict
                  (encodeProjectionImportRequest (ImportLegacyProjection CheckpointProjection))
              )
          )
          `shouldReturn` (200, "projection-import-accepted")
      it "does not compose the legacy caller-selected operation endpoints" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (post "/v1/operations/submit" "caller-selected-body")
          `shouldReturn` (503, "interpreter-unavailable\n")
        serveLA interpreter (get "/v1/operations/observe" "caller-selected-body")
          `shouldReturn` (503, "interpreter-unavailable\n")
      it "refuses a route owned by a different role with 404 route-not-owned" $ do
        interpreter <- freshLifecycleInterpreter True
        serveLA interpreter (post "/v1/tls-retention/store" "body")
          `shouldReturn` (404, "route-not-owned\n")
    describe "Lifecycle Authority production aggregate interpreter" $ do
      it "keeps operation routes unavailable on the raw context-free interpreter" $ do
        (interpreter, revisionRef) <- freshAggregateLifecycleInterpreter True
        serveLA
          interpreter
          ( post
              "/v1/operations/submit"
              (encoded (AuthorityOperationSubmitPayload "request-a" "digest-a"))
          )
          `shouldReturn` (503, "interpreter-unavailable\n")
        serveLA
          interpreter
          ( post
              "/v1/authority/control"
              (encoded AuthorityControlBeginMigration)
          )
          `shouldReturn` (200, "authority-migration-started")
        serveLA
          interpreter
          ( post
              "/v1/operations/submit"
              (encoded (AuthorityOperationSubmitPayload "request-a" "digest-a"))
          )
          `shouldReturn` (503, "interpreter-unavailable\n")
        serveLA
          interpreter
          ( post
              "/v1/operations/submit"
              (encoded (AuthorityOperationSubmitPayload "request-b" "digest-b"))
          )
          `shouldReturn` (503, "interpreter-unavailable\n")
        readIORef revisionRef `shouldReturn` 1
      it "keeps a missing trusted projection registration fail closed" $ do
        (interpreter, revisionRef) <- freshAggregateLifecycleInterpreter True
        serveLA
          interpreter
          ( post
              "/v1/migration/import"
              ( LazyByteString.toStrict
                  (encodeProjectionImportRequest (ImportLegacyProjection CheckpointProjection))
              )
          )
          `shouldReturn` (503, "projection-import-authority-read-failed")
        readIORef revisionRef `shouldReturn` 0
      it "owns the closed retained SES lease route and fails closed without registration" $ do
        (interpreter, revisionRef) <- freshAggregateLifecycleInterpreter True
        (status, body) <-
          serveLA
            interpreter
            ( post
                "/v1/authority/retained-ses-lease"
                (encoded ObserveRetainedSesLease)
            )
        status `shouldBe` 503
        decodeStrictResponse body
          `shouldBe` Right (RetainedSesLeaseUnavailable "fixture lease registration absent")
        readIORef revisionRef `shouldReturn` 0
      it "keeps the checkpoint route unavailable on the raw context-free interpreter" $ do
        (interpreter, revisionRef) <- freshAggregateLifecycleInterpreter True
        serveLA
          interpreter
          ( post
              "/v1/authority/pulumi-checkpoint"
              (encoded (ObservePulumiCheckpoint "aws-test"))
          )
          `shouldReturn` (503, "interpreter-unavailable\n")
        readIORef revisionRef `shouldReturn` 0
    describe "TLS Retention interpreter (store + restore through the seam)" $ do
      it "dispatches a well-formed envelope store and preserves the binary receipt" $ do
        interpreter <- freshTlsInterpreter Nothing True
        (status, body) <-
          serveTls
            interpreter
            (post "/v1/tls-retention/store" (encoded (TlsStorePayload ref1 tlsEnvelope)))
        status `shouldBe` 200
        (decodeStrictResponse body :: Either ControlPlaneRequestCodecError TlsRetentionReceipt)
          `shouldSatisfy` isRight
      it "dispatches restore and preserves the exact binary envelope observation" $ do
        interpreter <- freshTlsInterpreter (Just (ref1, tlsEnvelope)) True
        (status, body) <-
          serveTls
            interpreter
            (post "/v1/tls-retention/restore" (encoded (TlsRestorePayload ref1)))
        status `shouldBe` 200
        case decodeStrictResponse body of
          Right (TlsEnvelopePresent envelope _) -> envelope `shouldBe` tlsEnvelope
          other -> expectationFailure ("expected TLS envelope observation, got " <> show other)
      it "maps a malformed store body to a 400 bad request through the seam" $ do
        interpreter <- freshTlsInterpreter Nothing True
        serveTls interpreter (post "/v1/tls-retention/store" "not-a-cbor-envelope")
          `shouldReturn` (400, "tls-store:bad-request:invalid")
      it "serves the injected readiness probe" $ do
        notReady <- freshTlsInterpreter Nothing False
        serveTls notReady "GET /readyz HTTP/1.1\r\n\r\n" `shouldReturn` (503, "not-ready\n")
    describe "Authority Backup interpreter (copy + observe through the seam)" $ do
      it "dispatches opaque copy and observe with canonical binary bodies" $ do
        interpreter <- freshBackupInterpreter True
        (copyStatus, copyBody) <-
          serveBackup
            interpreter
            ( post
                "/v1/authority-backup/copy"
                (encoded (AuthorityBackupCopyRequest AuthorityAggregateEnvelope backupCiphertext))
            )
        copyStatus `shouldBe` 200
        (decodeStrictResponse copyBody :: Either ControlPlaneRequestCodecError AuthorityBackupReceipt)
          `shouldSatisfy` isRight
        (observeStatus, observeBody) <-
          serveBackup
            interpreter
            ( get
                "/v1/authority-backup/observe"
                ( encoded
                    ( AuthorityBackupObserveRequest
                        AuthorityAggregateEnvelope
                        (authorityBackupCiphertextDigest backupCiphertext)
                    )
                )
            )
        observeStatus `shouldBe` 200
        case decodeStrictResponse observeBody of
          Right (AuthorityBackupBlobPresent ciphertext _) -> ciphertext `shouldBe` backupCiphertext
          other -> expectationFailure ("expected Backup blob observation, got " <> show other)
      it "returns 404 with a canonical missing observation" $ do
        interpreter <- freshBackupInterpreter True
        let missingDigest = authorityBackupCiphertextDigest backupCiphertext
        (status, body) <-
          serveBackup
            interpreter
            ( get
                "/v1/authority-backup/observe"
                (encoded (AuthorityBackupObserveRequest AuthorityAggregateEnvelope missingDigest))
            )
        status `shouldBe` 404
        decodeStrictResponse body `shouldBe` Right AuthorityBackupBlobMissing
      it "maps a malformed copy body to a 400 bad request through the seam" $ do
        interpreter <- freshBackupInterpreter True
        serveBackup interpreter (post "/v1/authority-backup/copy" "not-a-cbor-envelope")
          `shouldReturn` (400, "backup-copy:bad-request:invalid")
      it "refuses a route owned by a different role with 404 route-not-owned" $ do
        interpreter <- freshBackupInterpreter True
        serveBackup interpreter (post "/v1/tls-retention/store" "body")
          `shouldReturn` (404, "route-not-owned\n")
      it "serves the injected readiness probe" $ do
        notReady <- freshBackupInterpreter False
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
  src = SourceSecretRef "uid-1" "rv-1"
  tlsEnvelope = either (error . Text.unpack) id (mkTlsSealedEnvelope "tls-ciphertext" "wrapped-dek")
  ref1 =
    RetainedTlsRef
      (RetentionVersion 1)
      (CertIdentity "serial-1" "spki-A" 1000)
      (tlsSealedEnvelopeDigest tlsEnvelope)
      src
  backupCiphertext = either (error . Text.unpack) id (mkAuthorityBackupCiphertext "backup-ciphertext")
  serveLA interpreter request =
    serveControlPlaneRequest fixtureRoleReadinessResolver interpreter LifecycleAuthorityRuntime request
  serveTls interpreter request = serveControlPlaneRequest fixtureRoleReadinessResolver interpreter TlsRetentionRuntime request
  serveBackup interpreter request = serveControlPlaneRequest fixtureRoleReadinessResolver interpreter AuthorityBackupRuntime request
  serveProvider interpreter request = serveControlPlaneRequest fixtureRoleReadinessResolver interpreter ProviderWorkerRuntime request
  submitReconcile =
    ProviderWorkApplyPayload
      { applyCommandKind = SubmitCommand
      , applyIntentKind = ReconcileStackIntent
      , applyResourceRef = "aws-eks"
      , applySecondaryRef = ""
      , applyTertiaryRef = ""
      , applyRequestedRevision = 3
      , applyStackConfig =
          Just (either (error . show) id (mkAwsEksProviderStackConfig "127.0.0.1/32"))
      , applyCoordinate = ""
      }
  submitStaging = submitReconcile {applyResourceRef = "staging"}
freshLifecycleInterpreter :: Bool -> IO (RoleInterpreter IO)
freshLifecycleInterpreter ready = do
  migrationRepository <- freshMigrationRepository
  let projectionConfig =
        either (error . show) id $
          mkProjectionImportCodecConfig
            defaultSesLeasePolicy
            ( either (error . show) id $
                mkRegisteredTargetSet
                  1
                  [ either (error . show) id $
                      mkTargetClusterSecretSink
                        "home"
                        "secret"
                        "keycloak/smtp"
                  ]
            )
            4096
      projectionSource :: LegacyProjectionSource IO Word
      projectionSource =
        LegacyProjectionSource (\_ -> pure LegacyProjectionMissing)
      projectionTarget :: ProjectionImportTarget IO Word
      projectionTarget =
        ProjectionImportTarget
          { observeImportedProjection = \_ -> pure ProjectionTargetMissing
          , initializeImportedProjection = \_ _ ->
              pure (ProjectionTargetWriteUnobservable "unexpected initialize")
          }
      projectionHandler =
        mkProjectionImportHandler
          4096
          4096
          projectionConfig
          migrationRepository
          projectionSource
          projectionTarget
  pure
    ( lifecycleAuthorityInterpreter
        4096
        (if ready then fixtureReadyRoleReadinessSource else fixtureUnreadyRoleReadinessSource)
        "cluster-a"
        (pure (Right 123456))
        migrationRepository
        projectionHandler
        fixturePulumiCheckpointHandler
    )

freshAggregateLifecycleInterpreter
  :: Bool
  -> IO (RoleInterpreter IO, IORef Word)
freshAggregateLifecycleInterpreter ready = do
  stateRef <- newIORef openedAuthorityAggregate
  revisionRef <- newIORef (0 :: Word)
  let repository =
        AuthorityAdmissionRepository
          { readAuthorityAdmission = do
              revision <- readIORef revisionRef
              state <- readIORef stateRef
              pure (Right (AuthorityAdmissionSnapshot revision state))
          , compareAndSwapAuthorityAdmission = \expected state -> do
              revision <- readIORef revisionRef
              if revision /= expected
                then pure (Left "authority admission CAS conflict")
                else do
                  writeIORef stateRef state
                  writeIORef revisionRef (revision + 1)
                  pure (Right ())
          }
      interpreter =
        lifecycleAuthorityAdmissionInterpreter
          4096
          (if ready then fixtureReadyRoleReadinessSource else fixtureUnreadyRoleReadinessSource)
          "cluster-a"
          (pure (Right 123456))
          (const (Right "fixture-authority-envelope"))
          repository
          (unavailableProjectionImportHandler "fixture registration absent")
          (resolvingRetainedSesLeaseHandler (pure (Left "fixture lease registration absent")))
          fixturePulumiCheckpointHandler
  pure (interpreter, revisionRef)

fixturePulumiCheckpointHandler :: PulumiCheckpointHandler IO
fixturePulumiCheckpointHandler =
  mkPulumiCheckpointHandler
    PulumiCheckpointRepository
      { observeRegisteredPulumiCheckpoint = \_callerSlot _ -> pure PulumiCheckpointMissing
      , publishRegisteredPulumiCheckpoint = \_callerSlot _ _ _ ->
          pure (PulumiCheckpointPublicationUnavailable "fixture unavailable")
      , retireRegisteredPulumiCheckpoint = \_callerSlot _ _ ->
          pure (PulumiCheckpointRetirementUnavailable "fixture unavailable")
      }

openedAuthorityAggregate :: AuthorityAdmissionAggregate
openedAuthorityAggregate =
  foldl
    (\state command -> snd (stepAuthorityAdmission state command))
    initial
    [ ApplyAuthorityGenesis
        ( BeginGenesisEstablishment
            (GenesisPlan "fixture-plan" "s3://fixture/authority-backup")
        )
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]
 where
  initial =
    either
      (error . show)
      id
      (initialCleanInstallAuthority 4 8)

freshTlsInterpreter
  :: Maybe (RetainedTlsRef, TlsSealedEnvelope)
  -> Bool
  -> IO (RoleInterpreter IO)
freshTlsInterpreter initial ready = do
  stateRef <- newIORef initial
  let repository =
        TlsRetentionRepository
          { storeTlsEnvelope = \reference envelope -> do
              writeIORef stateRef (Just (reference, envelope))
              pure
                ( Right
                    TlsRetentionReceipt
                      { tlsRetentionReceiptReference = reference
                      , tlsRetentionReceiptEnvelopeDigest = tlsSealedEnvelopeDigest envelope
                      , tlsRetentionReceiptObjectVersion = "fixture-etag"
                      }
                )
          , restoreTlsEnvelope = \reference -> do
              observed <- readIORef stateRef
              pure $ case observed of
                Just (storedReference, envelope)
                  | storedReference == reference ->
                      Right
                        ( TlsEnvelopePresent
                            envelope
                            TlsRetentionReceipt
                              { tlsRetentionReceiptReference = reference
                              , tlsRetentionReceiptEnvelopeDigest = tlsSealedEnvelopeDigest envelope
                              , tlsRetentionReceiptObjectVersion = "fixture-etag"
                              }
                        )
                _ -> Right TlsEnvelopeMissing
          }
  pure
    ( tlsRetentionInterpreter
        4096
        (if ready then fixtureReadyRoleReadinessSource else fixtureUnreadyRoleReadinessSource)
        repository
    )

freshBackupInterpreter :: Bool -> IO (RoleInterpreter IO)
freshBackupInterpreter ready = do
  stateRef <- newIORef Nothing
  let repository =
        AuthorityBackupRepository
          { copyAuthorityBackupBlob = \blobClass ciphertext -> do
              let digest = authorityBackupCiphertextDigest ciphertext
                  receipt =
                    AuthorityBackupReceipt
                      { authorityBackupReceiptClass = blobClass
                      , authorityBackupReceiptDigest = digest
                      , authorityBackupReceiptObjectVersion = "fixture-etag"
                      }
              writeIORef stateRef (Just (blobClass, digest, ciphertext, receipt))
              pure (Right receipt)
          , observeAuthorityBackupBlob = \blobClass digest -> do
              observed <- readIORef stateRef
              pure $ case observed of
                Just (storedClass, storedDigest, ciphertext, receipt)
                  | storedClass == blobClass && storedDigest == digest ->
                      Right (AuthorityBackupBlobPresent ciphertext receipt)
                _ -> Right AuthorityBackupBlobMissing
          }
  pure
    ( authorityBackupInterpreter
        4096
        (if ready then fixtureReadyRoleReadinessSource else fixtureUnreadyRoleReadinessSource)
        repository
    )

freshProviderInterpreter :: ProviderWorkState -> Bool -> IO (RoleInterpreter IO)
freshProviderInterpreter initial ready = do
  stateRef <- newIORef initial
  let repository =
        ProviderWorkRepository
          { readProviderWorkState = readIORef stateRef
          , readRegisteredProviderResources =
              pure (mkRegisteredProviderResources ["stack:aws-eks", "ses:sending-identity"])
          , readBoundProviderRevision = pure (either (error . show) id (mkProviderRevision 2))
          , readProviderAuthorityNow = pure (authorityTimeFromMicros 1000)
          , readProviderSessionDeadline = pure (authorityTimeFromMicros 5000)
          , commitProviderWorkState = \state -> do
              writeIORef stateRef state
              pure (Right ())
          }
  pure
    ( providerWorkerInterpreter
        4096
        (if ready then fixtureReadyRoleReadinessSource else fixtureUnreadyRoleReadinessSource)
        repository
    )

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

decodeStrictResponse
  :: (Serialise a)
  => ByteString
  -> Either ControlPlaneRequestCodecError a
decodeStrictResponse =
  decodeControlPlaneResponse (1024 * 1024) . LazyByteString.fromStrict

isRight :: Either left right -> Bool
isRight value = case value of
  Left _ -> False
  Right _ -> True

migrationBody :: MigrationCommand -> ByteString
migrationBody = LazyByteString.toStrict . encodeMigrationCommand
