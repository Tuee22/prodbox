{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneAuthorityBackupEndpoint (controlPlaneAuthorityBackupEndpointSuite) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation (..)
  , allAuthenticatedRolePlainResponseCauses
  , authenticatedRolePlainResponse
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityBackupAdapter
  ( authorityBackupBlobObjectNameForClass
  , authorityBackupRepositoryWithTransport
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupClientError (..)
  , AuthorityAggregateBackupObservation (..)
  , decodeAuthorityAggregateBackupResponse
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
import Prodbox.ControlPlane.AuthorityBackupExportClient
  ( AuthorityBackupExportResponseObservation (..)
  , authorityBackupExportResponseObservationToken
  , classifyAuthorityBackupExportResponse
  , mkAuthorityBackupExportClient
  )
import Prodbox.ControlPlane.AuthorityBackupExportEndpoint
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminFirstReconcileProjection (..)
  )
import Prodbox.ControlPlane.Client (ControlPlaneResponse (..))
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.DedicatedAdapterStore
  ( AdapterObjectObservation (..)
  , AdapterObjectVersion
  , AdapterPutResult (..)
  , DedicatedAdapterKind (AuthorityBackupAdapter)
  , DedicatedAdapterStoreError (..)
  , DedicatedAdapterTransport (..)
  , adapterBindingTransport
  , adapterObjectNameText
  , authorityBackupBlobObjectName
  , authorityBackupCredentialPath
  , authorityBackupStorePrefix
  , awsS3EndpointForRegion
  , deferredAuthorityBackupBinding
  , mkAdapterObjectVersion
  , mkAuthorityBackupStoreConfig
  , mkTlsRetentionStoreConfig
  , tlsRetentionCredentialPath
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution (mkTargetAgentIdentity)
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , initialCleanInstallAuthority
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.BackupRepair (BackupHealth (..))
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (BeginGenesisEstablishment)
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , mkAuthorityBackupIamParameters
  , mkGatewayDnsIamParameters
  , mkLifecycleProviderIamParameters
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , defaultFirstReconcileProvisioningPlan
  , firstReconcilePlanMembers
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Settings (Credentials (..))
import TestSupport

controlPlaneAuthorityBackupEndpointSuite :: SuiteBuilder ()
controlPlaneAuthorityBackupEndpointSuite =
  describe "Sprint 4.50 Authority Backup opaque-byte endpoint" $ do
    it "fixes distinct credentials and the exact durable backup namespace" $ do
      authorityBackupCredentialPath `shouldBe` "aws/authority-backup-store"
      tlsRetentionCredentialPath `shouldBe` "aws/tls-retention-store"
      let config =
            mustRight
              ( mkAuthorityBackupStoreConfig
                  "home"
                  (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
                  (fixtureAwsRegion FixtureCaCentral1)
                  "prodbox-retained"
                  "authority-backup-store/home"
              )
      authorityBackupStorePrefix config `shouldBe` "authority-backup-store/home"
    it "rejects a generic endpoint and cross-role prefix substitution" $ do
      mkAuthorityBackupStoreConfig
        "home"
        "https://s3.example.invalid"
        (fixtureAwsRegion FixtureCaCentral1)
        "prodbox-retained"
        "authority-backup-store/home"
        `shouldSatisfy` isLeft
      mkAuthorityBackupStoreConfig
        "home"
        (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
        (fixtureAwsRegion FixtureCaCentral1)
        "prodbox-retained"
        "public-edge-tls/home-local/test.example"
        `shouldSatisfy` isLeft
      mkTlsRetentionStoreConfig
        "home"
        (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
        (fixtureAwsRegion FixtureCaCentral1)
        "prodbox-retained"
        "home-local"
        "test.example"
        "authority-backup-store/home"
        `shouldSatisfy` isLeft
    it "keeps one binding closed until its per-operation credential loader succeeds" $ do
      available <- newIORef False
      loadCount <- newIORef (0 :: Int)
      (native, _, putCount) <- freshMemoryTransport False
      let config =
            mustRight
              ( mkAuthorityBackupStoreConfig
                  "home"
                  (awsS3EndpointForRegion (fixtureAwsRegion FixtureCaCentral1))
                  (fixtureAwsRegion FixtureCaCentral1)
                  "prodbox-retained"
                  "authority-backup-store/home"
              )
          loadTransport = do
            modifyIORef' loadCount (+ 1)
            current <- readIORef available
            pure $
              if current
                then Right native
                else Left (DedicatedAdapterVaultReadFailed authorityBackupCredentialPath "status-404")
          transport =
            adapterBindingTransport
              (deferredAuthorityBackupBinding config loadTransport)
          objectName =
            mustRight
              (authorityBackupBlobObjectName "checkpoint" (Text.replicate 64 "a"))
      adapterObjectStoreReady transport `shouldReturn` False
      putAdapterObjectIfAbsent transport objectName "before-genesis"
        `shouldReturn` Left "Authority Backup store credential is unavailable"
      readIORef putCount `shouldReturn` 0
      writeIORef available True
      adapterObjectStoreReady transport `shouldReturn` True
      putAdapterObjectIfAbsent transport objectName "after-genesis"
        `shouldReturn` Right AdapterPutApplied
      observed <- observeAdapterObject transport objectName
      observed `shouldSatisfy` isObservedBytes "after-genesis"
      readIORef putCount `shouldReturn` 1
      readIORef loadCount `shouldReturn` 5
    it "copies opaque ciphertext and returns a canonical binary receipt" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = authorityBackupRepositoryWithTransport transport
          ciphertext = mustRight (mkAuthorityBackupCiphertext "opaque-ciphertext")
          request = AuthorityBackupCopyRequest AuthorityAggregateEnvelope ciphertext
      result <- serveBackupCopyRequest 4096 repository (encodeControlPlaneRequest request)
      authorityBackupHttpStatus result `shouldBe` ReplyOk
      authorityBackupSummary result `shouldBe` "backup-copy:read-back-confirmed"
      case result of
        AuthorityBackupCopySucceeded receipt ->
          decodeControlPlaneResponse
            4096
            (LazyByteString.fromStrict (authorityBackupCopyResponseBody result))
            `shouldBe` Right receipt
        other -> expectationFailure ("expected copy receipt, got " <> show other)
    it "recovers an applied immutable PUT after its response is lost" $ do
      (transport, _, putCount) <- freshMemoryTransport True
      let repository = authorityBackupRepositoryWithTransport transport
          ciphertext = mustRight (mkAuthorityBackupCiphertext "response-loss-ciphertext")
      copied <- copyAuthorityBackupBlob repository AuthorityCheckpointBlob ciphertext
      copied `shouldSatisfy` isRight
      readIORef putCount `shouldReturn` 1
      observed <-
        observeAuthorityBackupBlob
          repository
          AuthorityCheckpointBlob
          (authorityBackupCiphertextDigest ciphertext)
      case observed of
        Right (AuthorityBackupBlobPresent readBack _) ->
          authorityBackupCiphertextBytes readBack
            `shouldBe` authorityBackupCiphertextBytes ciphertext
        other -> expectationFailure ("expected exact read-back, got " <> show other)
    it "accepts an immutable conflict only when exact read-back bytes match" $ do
      (transport, _, putCount) <- freshMemoryTransport False
      let repository = authorityBackupRepositoryWithTransport transport
          ciphertext = mustRight (mkAuthorityBackupCiphertext "same-ciphertext")
      first <- copyAuthorityBackupBlob repository AuthorityCheckpointBlob ciphertext
      second <- copyAuthorityBackupBlob repository AuthorityCheckpointBlob ciphertext
      first `shouldSatisfy` isRight
      second `shouldSatisfy` isRight
      readIORef putCount `shouldReturn` 2
    it "fails closed when an existing content-addressed object has different bytes" $ do
      (transport, objectsRef, _) <- freshMemoryTransport False
      let repository = authorityBackupRepositoryWithTransport transport
          ciphertext = mustRight (mkAuthorityBackupCiphertext "expected-ciphertext")
          digest = authorityBackupCiphertextDigest ciphertext
          objectName =
            mustRight
              (authorityBackupBlobObjectName "checkpoint" (authorityBackupDigestText digest))
      version <- pure (mustRight (mkAdapterObjectVersion "corrupt-etag"))
      writeIORef
        objectsRef
        (Map.singleton (adapterObjectNameText objectName) (version, "different-ciphertext"))
      copyAuthorityBackupBlob repository AuthorityCheckpointBlob ciphertext
        `shouldReturn` Left "Authority backup read-back bytes did not match"
    it "names an adapter object for every backup blob class" $ do
      -- Sprint 4.87: the class-to-segment mapping crosses a stringly-typed
      -- seam into the dedicated adapter store, and a class the store could not
      -- name refused every copy of that class at run time rather than failing
      -- to compile.  Enumerating the class is the guard.
      let digest =
            authorityBackupCiphertextDigest
              (mustRight (mkAuthorityBackupCiphertext "class-naming"))
          named =
            [ (blobClass, authorityBackupBlobObjectNameForClass blobClass digest)
            | blobClass <- [minBound .. maxBound]
            ]
      -- Sprint 4.86 adds the fourth class: the pre-uninstall cleanup report,
      -- which node 7 requires the independent Backup Adapter to read back.
      length named `shouldBe` 4
      mapM_ (\(_, name) -> name `shouldSatisfy` isRight) named
      length
        (List.nub [adapterObjectNameText (mustRight name) | (_, name) <- named])
        `shouldBe` 4
      -- The count is pinned deliberately: adding a class must force a decision
      -- here rather than pass by construction.
      length named `shouldBe` length (List.nub [show blobClass | (blobClass, _) <- named])

    it "distinguishes missing and corrupt observations" $ do
      (transport, objectsRef, _) <- freshMemoryTransport False
      let repository = authorityBackupRepositoryWithTransport transport
          ciphertext = mustRight (mkAuthorityBackupCiphertext "expected")
          digest = authorityBackupCiphertextDigest ciphertext
      observeAuthorityBackupBlob repository AuthorityCheckpointBlob digest
        `shouldReturn` Right AuthorityBackupBlobMissing
      let objectName =
            mustRight
              (authorityBackupBlobObjectName "checkpoint" (authorityBackupDigestText digest))
          version = mustRight (mkAdapterObjectVersion "etag-corrupt")
      writeIORef
        objectsRef
        (Map.singleton (adapterObjectNameText objectName) (version, "wrong"))
      observed <- observeAuthorityBackupBlob repository AuthorityCheckpointBlob digest
      observed `shouldBe` Right (AuthorityBackupBlobCorrupt "Authority backup digest mismatch")
    it "refuses malformed, oversized, empty, and malformed-digest inputs" $ do
      (transport, _, _) <- freshMemoryTransport False
      let repository = authorityBackupRepositoryWithTransport transport
      serveBackupCopyRequest 4096 repository "not-cbor"
        `shouldReturn` AuthorityBackupCopyBadRequest ControlPlaneRequestInvalid
      let ciphertext = mustRight (mkAuthorityBackupCiphertext "ciphertext")
          request = AuthorityBackupCopyRequest AuthorityAggregateEnvelope ciphertext
      serveBackupCopyRequest 2 repository (encodeControlPlaneRequest request)
        `shouldReturn` AuthorityBackupCopyBadRequest ControlPlaneRequestTooLarge
      mkAuthorityBackupCiphertext ByteString.empty `shouldSatisfy` isLeft
      let aggregateOversized =
            mustRight
              ( mkAuthorityBackupCiphertext
                  ( ByteString.replicate
                      (authorityBackupMaximumAggregateCiphertextBytes + 1)
                      0
                  )
              )
      validateAuthorityBackupCiphertextForClass
        AuthorityAggregateEnvelope
        aggregateOversized
        `shouldSatisfy` isLeft
      validateAuthorityBackupCiphertextForClass
        AuthorityCheckpointBlob
        aggregateOversized
        `shouldBe` Right ()
      mkAuthorityBackupDigest "not-a-sha256" `shouldSatisfy` isLeft
    it "redacts raw ciphertext from Show" $ do
      let ciphertext = mustRight (mkAuthorityBackupCiphertext "do-not-log-this")
      show ciphertext `shouldNotContain` "do-not-log-this"
      show ciphertext `shouldContain` "15 bytes"
    it "exports the exact aggregate only for its retained genesis purpose" $ do
      frozen <- pure (mustRight (initialCleanInstallAuthority 4 8))
      let plan = GenesisPlan "genesis-plan-digest" "authority-backup-store/home"
          aggregate =
            snd
              ( stepAuthorityAdmission
                  frozen
                  (ApplyAuthorityGenesis (BeginGenesisEstablishment plan))
              )
          repository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission =
                  pure (Right (AuthorityAdmissionSnapshot (1 :: Word) aggregate))
              , compareAndSwapAuthorityAdmission = \_ _ ->
                  pure (Left "export must not write")
              }
          request purpose =
            LazyByteString.toStrict
              (encodeControlPlaneRequest (AuthorityBackupExportRequest purpose))
      exported <-
        serveAuthorityBackupExportRequest
          4096
          (const (Right "canonical-retained-aggregate"))
          repository
          (request (ExportGenesisAggregate "genesis-plan-digest"))
      authorityBackupExportHttpStatus exported `shouldBe` ReplyOk
      case exported of
        AuthorityBackupExported response -> do
          authorityBackupExportEnvelope response
            `shouldBe` "canonical-retained-aggregate"
          authorityBackupExportDigest response `shouldSatisfy` ((== 64) . Text.length)
          decodeControlPlaneResponse
            authorityBackupExportMaximumResponseBytes
            (LazyByteString.fromStrict (authorityBackupExportResponseBody exported))
            `shouldBe` Right response
        other -> expectationFailure ("expected aggregate export, got " <> show other)
      mismatched <-
        serveAuthorityBackupExportRequest
          4096
          (const (Right "must-not-export"))
          repository
          (request (ExportGenesisAggregate "different-plan"))
      mismatched `shouldBe` AuthorityBackupExportPurposeMismatch
      authorityBackupExportHttpStatus mismatched `shouldBe` ReplyConflict
      authorityBackupExportResponseBody mismatched `shouldBe` "purpose-mismatch"
    it "classifies the export response shape without retaining response values" $ do
      let responseA = AuthorityBackupExportResponse "private-aggregate-a" "private-digest-a"
          responseB = AuthorityBackupExportResponse "private-aggregate-b" "private-digest-b"
          encoded value = LazyByteString.toStrict (encodeControlPlaneResponse value)
          observations = [minBound .. maxBound]
          tokens = fmap authorityBackupExportResponseObservationToken observations
      classifyAuthorityBackupExportResponse (encoded responseA)
        `shouldBe` AuthorityBackupExportResponseDirect
      classifyAuthorityBackupExportResponse
        (encoded (Right responseA :: Either Text AuthorityBackupExportResponse))
        `shouldBe` AuthorityBackupExportResponseEndpointSuccess
      classifyAuthorityBackupExportResponse
        (encoded (Right responseB :: Either Text AuthorityBackupExportResponse))
        `shouldBe` AuthorityBackupExportResponseEndpointSuccess
      classifyAuthorityBackupExportResponse
        (encoded (Left "private-failure-a" :: Either Text AuthorityBackupExportResponse))
        `shouldBe` AuthorityBackupExportResponseEndpointFailure
      classifyAuthorityBackupExportResponse
        (encoded (Left "private-failure-b" :: Either Text AuthorityBackupExportResponse))
        `shouldBe` AuthorityBackupExportResponseEndpointFailure
      classifyAuthorityBackupExportResponse ByteString.empty
        `shouldBe` AuthorityBackupExportResponseEmpty
      classifyAuthorityBackupExportResponse "not-canonical-cbor"
        `shouldBe` AuthorityBackupExportResponseOther
      List.nub tokens `shouldBe` tokens
    it "Sprint 2.125 classifies aggregate decode failures by exact authenticated-role pair" $ do
      let decodeAggregate response =
            decodeAuthorityAggregateBackupResponse response
              :: Either
                   AuthorityAggregateBackupClientError
                   AuthorityBackupBlobObservation
          wrongStatus status
            | replyStatusCode status == 500 = 503
            | otherwise = 500
      forM_ allAuthenticatedRolePlainResponseCauses $ \cause -> do
        let (status, body) = authenticatedRolePlainResponse cause
            known = AuthenticatedRolePlainResponseKnown cause
            invalidAt responseStatus responseBody =
              Left
                ( AuthorityAggregateBackupResponseInvalid
                    ControlPlaneRequestInvalid
                    ( if responseStatus == replyStatusCode status && responseBody == body
                        then known
                        else AuthenticatedRolePlainResponseOther
                    )
                )
        decodeAggregate (ControlPlaneResponse (replyStatusCode status) body)
          `shouldBe` invalidAt (replyStatusCode status) body
        decodeAggregate (ControlPlaneResponse (wrongStatus status) body)
          `shouldBe` invalidAt (wrongStatus status) body
        decodeAggregate
          (ControlPlaneResponse (replyStatusCode status) ("private-prefix" <> body))
          `shouldBe` invalidAt (replyStatusCode status) ("private-prefix" <> body)
        decodeAggregate
          (ControlPlaneResponse (replyStatusCode status) (body <> "private-suffix"))
          `shouldBe` invalidAt (replyStatusCode status) (body <> "private-suffix")
      decodeAggregate (ControlPlaneResponse 503 "private-aggregate-response-a")
        `shouldBe` Left
          ( AuthorityAggregateBackupResponseInvalid
              ControlPlaneRequestInvalid
              AuthenticatedRolePlainResponseOther
          )
      decodeAggregate (ControlPlaneResponse 503 "different-private-aggregate-response-b")
        `shouldBe` Left
          ( AuthorityAggregateBackupResponseInvalid
              ControlPlaneRequestInvalid
              AuthenticatedRolePlainResponseOther
          )
    it "retains the immutable Adapter digest and re-observes that exact backup" $ do
      let envelope = "canonical-retained-aggregate"
          ciphertext = mustRight (mkAuthorityBackupCiphertext envelope)
          receipt =
            AuthorityBackupReceipt
              { authorityBackupReceiptClass = AuthorityAggregateEnvelope
              , authorityBackupReceiptDigest = authorityBackupCiphertextDigest ciphertext
              , authorityBackupReceiptObjectVersion = "adapter-version-1"
              }
          exportClient = mkAuthorityBackupExportClient (const (pure (Right envelope)))
          backupClient =
            AuthorityAggregateBackupClient
              { copyAuthorityAggregateBackup = const (pure (Right receipt))
              , observeAuthorityAggregateBackup = \digest ->
                  pure
                    ( if digest == authorityBackupDigestText (authorityBackupReceiptDigest receipt)
                        then Right (AuthorityAggregateBackupCurrent ciphertext receipt)
                        else Right AuthorityAggregateBackupMissing
                    )
              }
          plan = GenesisPlan "genesis-plan" "authority-backup-store/home"
      copied <- copyGenesisAggregateForAdmission exportClient backupClient plan
      copied
        `shouldBe` Right
          (BackupReceipt (authorityBackupDigestText (authorityBackupReceiptDigest receipt)))
      case copied of
        Left detail -> expectationFailure (Text.unpack detail)
        Right retained ->
          observeRetainedAuthorityBackupHealth backupClient retained
            `shouldReturn` Right BackupHealthy
      retainedTargetGeneration
        ( TargetAgentGenerationReceipt
            "aws-admin-target-v1:7:12:commitment:request-digest"
        )
        `shouldBe` Right 7
      retainedTargetGeneration (TargetAgentGenerationReceipt "legacy-opaque")
        `shouldSatisfy` isLeft
    it "compiles a deterministic genesis AWS-admin intent bound to member zero" $ do
      let parameters =
            GenesisAwsAdminIntentParameters
              { genesisIntentIamParameters =
                  mustRight
                    ( mkAuthorityBackupIamParameters
                        (fixtureAwsRegion FixtureCaCentral1)
                        "prodbox-retained"
                        ["authority-backup-store/home"]
                    )
              , genesisIntentImageDigest = "sha256:" <> Text.replicate 64 "a"
              , genesisIntentAuthorityScope = "home"
              , genesisIntentAuthorityEndpoint =
                  "http://lifecycle-authority.lifecycle-authority.svc:8600"
              , genesisIntentSelectedAgent =
                  mustRight
                    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
              , genesisIntentDeadline = authorityTimeFromMicros 60000000
              }
          plan = GenesisPlan "genesis-plan-digest" "authority-backup-store/home"
      compileGenesisAwsAdminIntent parameters plan `shouldSatisfy` isRight
      compileGenesisAwsAdminIntent parameters plan
        `shouldBe` compileGenesisAwsAdminIntent parameters plan
    it "compiles the next normal first-reconcile member deterministically" $ do
      let parameters =
            GenesisAwsAdminIntentParameters
              { genesisIntentIamParameters =
                  mustRight
                    ( mkAuthorityBackupIamParameters
                        (fixtureAwsRegion FixtureCaCentral1)
                        "prodbox-retained"
                        ["authority-backup-store/home"]
                    )
              , genesisIntentImageDigest = "sha256:" <> Text.replicate 64 "a"
              , genesisIntentAuthorityScope = "home"
              , genesisIntentAuthorityEndpoint =
                  "http://lifecycle-authority.lifecycle-authority.svc:8600"
              , genesisIntentSelectedAgent =
                  mustRight
                    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
              , genesisIntentDeadline = authorityTimeFromMicros 60000000
              }
          member = case firstReconcilePlanMembers
            (defaultFirstReconcileProvisioningPlan (genesisIntentDeadline parameters)) of
            _ : value : _ -> value
            _ -> error "compiled first-reconcile plan omitted member one"
          providerIam =
            mustRight
              ( mkLifecycleProviderIamParameters
                  (fixtureAwsRegion FixtureCaCentral1)
                  "123456789012"
                  "prodbox-provider-role"
              )
          compiled = compileFirstReconcileAwsAdminIntent parameters member providerIam
      compiled `shouldSatisfy` isRight
      compiled `shouldBe` compileFirstReconcileAwsAdminIntent parameters member providerIam
      compileFirstReconcileAwsAdminIntent
        parameters
        member
        (genesisIntentIamParameters parameters)
        `shouldSatisfy` isLeft
    it "Sprint 2.108 re-observes each retained member under the fresh active deadline" $ do
      let parameters =
            GenesisAwsAdminIntentParameters
              { genesisIntentIamParameters =
                  mustRight
                    ( mkAuthorityBackupIamParameters
                        (fixtureAwsRegion FixtureCaCentral1)
                        "prodbox-retained"
                        ["authority-backup-store/home"]
                    )
              , genesisIntentImageDigest = "sha256:" <> Text.replicate 64 "a"
              , genesisIntentAuthorityScope = "home"
              , genesisIntentAuthorityEndpoint =
                  "http://lifecycle-authority.lifecycle-authority.svc:8600"
              , genesisIntentSelectedAgent =
                  mustRight
                    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
              , genesisIntentDeadline = authorityTimeFromMicros 60000000
              }
          credentials =
            Credentials
              { access_key_id = "AKIATEST"
              , secret_access_key = "secret"
              , session_token = Nothing
              , region = (fixtureAwsRegion FixtureCaCentral1)
              }
          continuation credentialClass memberIndex digestByte =
            AwsAdminFirstReconcileProjection
              { awsAdminFirstReconcileClass = credentialClass
              , awsAdminFirstReconcileMemberIndex = memberIndex
              , awsAdminFirstReconcileMemberDigest = Text.replicate 64 digestByte
              , awsAdminFirstReconcileDeadlineMicros = 10000000
              }
          firstShow :: (Show err) => Either err value -> Either Text value
          firstShow = either (Left . Text.pack . show) Right
      continuations <-
        newIORef
          [ continuation LifecycleProviderCredential 1 "c"
          , continuation GatewayDnsCredential 2 "d"
          ]
      coordinated <- newIORef ([] :: [AwsCredentialClass])
      activeDeadlines <- newIORef ([] :: [Natural])
      let observe = atomicModifyIORef' continuations popContinuation
          resolveIam _ credentialClass = pure $ case credentialClass of
            LifecycleProviderCredential ->
              firstShow
                ( mkLifecycleProviderIamParameters
                    (fixtureAwsRegion FixtureCaCentral1)
                    "123456789012"
                    "prodbox-lifecycle-provider"
                )
            GatewayDnsCredential ->
              firstShow (mkGatewayDnsIamParameters (fixtureAwsRegion FixtureCaCentral1) "Z123456789")
            _ -> Left "unexpected class"
          coordinate _ intent = do
            modifyIORef'
              coordinated
              (<> [awsAdminPermitIntentCredentialClass intent])
            modifyIORef'
              activeDeadlines
              (<> [authorityTimeMicros (awsAdminPermitIntentDeadline intent)])
            pure (Right ())
      result <-
        reconcileRemainingFirstReconcileCredentialsWith
          observe
          (pure (Right credentials))
          parameters
          resolveIam
          coordinate
      result `shouldBe` Right ()
      readIORef coordinated
        `shouldReturn` [LifecycleProviderCredential, GatewayDnsCredential]
      readIORef activeDeadlines `shouldReturn` [60000000, 60000000]
    it "compiles repair from the retained epoch, generation, and backup digest" $ do
      let parameters =
            GenesisAwsAdminIntentParameters
              { genesisIntentIamParameters =
                  mustRight
                    ( mkAuthorityBackupIamParameters
                        (fixtureAwsRegion FixtureCaCentral1)
                        "prodbox-retained"
                        ["authority-backup-store/home"]
                    )
              , genesisIntentImageDigest = "sha256:" <> Text.replicate 64 "a"
              , genesisIntentAuthorityScope = "home"
              , genesisIntentAuthorityEndpoint =
                  "http://lifecycle-authority.lifecycle-authority.svc:8600"
              , genesisIntentSelectedAgent =
                  mustRight
                    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
              , genesisIntentDeadline = authorityTimeFromMicros 60000000
              }
          priorGeneration =
            TargetAgentGenerationReceipt
              ( "aws-admin-target-v1:1:4:"
                  <> Text.replicate 64 "c"
                  <> ":"
                  <> Text.replicate 64 "d"
              )
          repair =
            compileBackupRepairPermit
              "authority-backup-store/home"
              authorityEpochGenesis
              priorGeneration
              (BackupReceipt (Text.replicate 64 "e"))
      compileRepairAwsAdminIntent parameters repair `shouldSatisfy` isRight
      compileRepairAwsAdminIntent parameters repair
        `shouldBe` compileRepairAwsAdminIntent parameters repair

popContinuation
  :: [AwsAdminFirstReconcileProjection]
  -> ( [AwsAdminFirstReconcileProjection]
     , Either Text (Maybe AwsAdminFirstReconcileProjection)
     )
popContinuation remaining = case remaining of
  [] -> ([], Right Nothing)
  next : rest -> (rest, Right (Just next))

freshMemoryTransport
  :: Bool
  -> IO
       ( DedicatedAdapterTransport 'AuthorityBackupAdapter IO
       , IORef (Map Text (AdapterObjectVersion, ByteString))
       , IORef Int
       )
freshMemoryTransport loseFirstResponse = do
  objectsRef <- newIORef Map.empty
  loseResponseRef <- newIORef loseFirstResponse
  putCount <- newIORef 0
  let transport =
        DedicatedAdapterTransport
          { observeAdapterObject = \objectName -> do
              objects <- readIORef objectsRef
              pure $ case Map.lookup (adapterObjectNameText objectName) objects of
                Nothing -> Right AdapterObjectMissing
                Just (version, bytes) -> Right (AdapterObjectObserved version bytes)
          , putAdapterObjectIfAbsent = \objectName bytes -> do
              modifyIORef' putCount (+ 1)
              let key = adapterObjectNameText objectName
              objects <- readIORef objectsRef
              case Map.lookup key objects of
                Just _ -> pure (Right AdapterPutConflict)
                Nothing -> do
                  let version =
                        mustRight
                          (mkAdapterObjectVersion ("etag-" <> Text.pack (show (ByteString.length bytes))))
                  writeIORef objectsRef (Map.insert key (version, bytes) objects)
                  lose <- atomicModifyIORef' loseResponseRef (False,)
                  pure $ if lose then Left "PUT response lost" else Right AdapterPutApplied
          , adapterObjectStoreReady = pure True
          }
  pure (transport, objectsRef, putCount)

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

isRight :: Either left right -> Bool
isRight value = case value of
  Left _ -> False
  Right _ -> True

isObservedBytes
  :: ByteString
  -> Either Text AdapterObjectObservation
  -> Bool
isObservedBytes expected observation = case observation of
  Right (AdapterObjectObserved _ bytes) -> bytes == expected
  _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
