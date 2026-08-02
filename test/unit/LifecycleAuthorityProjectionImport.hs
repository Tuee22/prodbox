{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityProjectionImport
  ( lifecycleAuthorityProjectionImportSuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  , authorityAdmissionMigrationImportApplicator
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityAdmissionCommandRefusal (..)
  , AuthorityMigrationMode (..)
  , authorityAggregateMigration
  , initialCleanInstallAuthority
  , initialMigratingAuthority
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (GenesisPlan)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationImportCommand (..)
  , MigrationImportDecision (..)
  , MigrationProjection (..)
  , MigrationProjectionImport (..)
  , decodeMigrationState
  , migrationProjectionImports
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationImportApplyResult (..)
  , MigrationRepository (..)
  , StoredMigration (..)
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ChartLifetime, ClusterRetained)
  , TargetClusterSecretSink
  , mkChartLifetimeCoordinate
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , mkTargetClusterSecretSink
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease
  ( FencedCommitPermit
  , LeaseAcquireDecision (..)
  , LeaseCommitDecision (..)
  , LeaseGrant
  , LeaseKey
  , LeaseProjection
  , LeaseReleaseDecision (..)
  , OwnerNonce
  , authorityTimeFromMicros
  , beginLeaseAcquire
  , decideFencedCommit
  , decideLeaseAcquire
  , decideLeaseRelease
  , defaultSesLeasePolicy
  , encodeLeaseProjection
  , leaseObjectCoordinate
  , leaseProjectionActiveGrant
  , mkLeaseKey
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( decodeSmtpCommittedProjection
  , encodeSmtpCommittedProjection
  , mkCommittedSmtpCredential
  , mkSmtpAccessKeyId
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( RegisteredTargetSet
  , TargetCommitPrepareDecision (..)
  , TargetIntentProjection
  , decidePrepareTargetCommit
  , emptyTargetIntentProjection
  , encodeTargetIntentProjection
  , mkCredentialGeneration
  , mkRegisteredTargetSet
  , mkTargetIntentCoordinate
  , sha256TargetValueDigest
  )
import TestSupport

lifecycleAuthorityProjectionImportSuite :: SuiteBuilder ()
lifecycleAuthorityProjectionImportSuite =
  describe "Sprint 4.50 verified legacy projection import" $ do
    it "uses the real bounded/versioned codec for every projection family" $ do
      let fixtures =
            [ (LeaseProjection, encodeLeaseProjection activeLeaseProjection)
            , (CheckpointProjection, checkpointBytes)
            , (TargetIntentProjection, encodeTargetIntentProjection targetProjection)
            , (SmtpProjection, smtpBytes)
            ]
      mapM_
        ( \(projection, bytes) -> do
            decoded <- either (testFailure . show) pure (decodeCanonicalProjection codecConfig projection bytes)
            ByteString.null (canonicalProjectionBytes decoded) `shouldBe` False
            canonicalProjectionEvidence decoded `shouldSatisfy` isLegacyEvidence
        )
        fixtures

    it "binds released-lease and staged-target semantics into distinct evidence" $ do
      released <-
        either (testFailure . show) pure $
          decodeCanonicalProjection
            codecConfig
            LeaseProjection
            (encodeLeaseProjection releasedLeaseProjection)
      canonicalProjectionEvidence released `shouldSatisfy` isReleasedEvidence
      staged <-
        either (testFailure . show) pure $
          decodeCanonicalProjection
            codecConfig
            TargetIntentProjection
            (encodeTargetIntentProjection stagedTargetProjection)
      canonicalProjectionEvidence staged `shouldSatisfy` isStagedEvidence

    it "redacts projection bytes and store revisions from diagnostics" $ do
      canonical <-
        either (testFailure . show) pure $
          decodeCanonicalProjection codecConfig SmtpProjection smtpBytes
      show canonical `shouldNotContain` "sealed-smtp-material"
      show (LegacyProjectionObserved ("secret-revision" :: Text) smtpBytes)
        `shouldNotContain` "secret-revision"
      show (ProjectionTargetObserved ("secret-revision" :: Text) smtpBytes)
        `shouldNotContain` "secret-revision"
      show (ProjectionTargetWriteApplied ("secret-revision" :: Text))
        `shouldNotContain` "secret-revision"

    it "bounds and version-checks Pulumi checkpoint JSON before copying" $ do
      decodeCanonicalProjection codecConfig CheckpointProjection (ByteString.replicate 4097 0)
        `shouldBe` Left (ProjectionCheckpointTooLarge 4097 4096)
      decodeCanonicalProjection codecConfig CheckpointProjection "{\"version\":99,\"deployment\":{}}"
        `shouldBe` Left (ProjectionCheckpointUnsupportedVersion 99)
      decodeCanonicalProjection codecConfig CheckpointProjection "{\"version\":3}"
        `shouldBe` Left
          ( ProjectionCheckpointInvalid
              "checkpoint must contain exactly one of checkpoint or deployment"
          )

    it "copies canonical bytes, re-observes both stores, then records evidence" $ do
      sourceReads <- newIORef (0 :: Int)
      targetReads <- newIORef (0 :: Int)
      targetState <- newIORef Nothing
      migrationState <- newIORef Nothing
      migrationRevision <- newIORef (0 :: Word)
      let source =
            LegacyProjectionSource $ \projection -> do
              projection `shouldBe` CheckpointProjection
              modifyIORef' sourceReads (+ 1)
              pure (LegacyProjectionObserved ("legacy-v1" :: Text) checkpointBytes)
          target = normalTarget targetReads targetState
          repository = inMemoryMigrationRepository migrationState migrationRevision
      result <-
        importLegacyProjection
          codecConfig
          4096
          repository
          source
          target
          CheckpointProjection
      result `shouldSatisfy` isSuccessfulImport
      readIORef sourceReads `shouldReturn` 2
      readIORef targetReads `shouldReturn` 2
      canonical <-
        either (testFailure . show) (pure . canonicalProjectionBytes) $
          decodeCanonicalProjection codecConfig CheckpointProjection checkpointBytes
      readIORef targetState `shouldReturn` Just (1, canonical)
      stored <- readIORef migrationState
      case stored of
        Nothing -> expectationFailure "projection evidence was not persisted"
        Just value -> do
          state <- either (testFailure . show) pure (decodeMigrationState 4096 (storedMigrationBytes value))
          Map.lookup CheckpointProjection (migrationProjectionImports state)
            `shouldSatisfy` isLegacyEvidenceMaybe

    it "records positive missing only after both stores are stably missing" $ do
      sourceReads <- newIORef (0 :: Int)
      targetReads <- newIORef (0 :: Int)
      migrationState <- newIORef Nothing
      migrationRevision <- newIORef (0 :: Word)
      let source =
            LegacyProjectionSource $ \_ -> do
              modifyIORef' sourceReads (+ 1)
              pure (LegacyProjectionMissing :: LegacyProjectionObservation Text)
          target = missingTarget targetReads
      result <-
        importLegacyProjection
          codecConfig
          4096
          (inMemoryMigrationRepository migrationState migrationRevision)
          source
          target
          SmtpProjection
      fmap projectionImportEvidence result `shouldBe` Right ProjectionMissing
      readIORef sourceReads `shouldReturn` 2
      readIORef targetReads `shouldReturn` 2

    it "recovers an applied-but-response-lost initialize from authoritative read-back" $ do
      targetState <- newIORef Nothing
      targetReads <- newIORef (0 :: Int)
      migrationState <- newIORef Nothing
      migrationRevision <- newIORef (0 :: Word)
      let source = stableCheckpointSource
          target = responseLostTarget targetReads targetState
      result <-
        importLegacyProjection
          codecConfig
          4096
          (inMemoryMigrationRepository migrationState migrationRevision)
          source
          target
          CheckpointProjection
      result `shouldSatisfy` isSuccessfulImport
      readIORef migrationRevision `shouldReturn` 1

    it "refuses a changed source revision after copying and records no evidence" $ do
      observations <-
        newIORef
          [ LegacyProjectionObserved "legacy-v1" checkpointBytes
          , LegacyProjectionObserved "legacy-v2" checkpointBytes
          ]
      targetState <- newIORef Nothing
      targetReads <- newIORef (0 :: Int)
      migrationState <- newIORef Nothing
      migrationRevision <- newIORef (0 :: Word)
      let source = sourceSequence observations
      result <-
        importLegacyProjection
          codecConfig
          4096
          (inMemoryMigrationRepository migrationState migrationRevision)
          source
          (normalTarget targetReads targetState)
          CheckpointProjection
      result `shouldBe` Left (ProjectionImportSourceChanged CheckpointProjection)
      readIORef migrationRevision `shouldReturn` 0
      copiedTarget <- readIORef targetState
      copiedTarget `shouldSatisfy` (/= Nothing)

    it "keeps corrupt, unobservable, and conflicting observations distinct" $ do
      migrationState <- newIORef Nothing
      migrationRevision <- newIORef (0 :: Word)
      targetReads <- newIORef (0 :: Int)
      targetState <- newIORef (Just (1, "{\"version\":3,\"checkpoint\":{}}"))
      let repository = inMemoryMigrationRepository migrationState migrationRevision
          corruptSource =
            LegacyProjectionSource
              (\_ -> pure (LegacyProjectionCorrupt "bad envelope" :: LegacyProjectionObservation Text))
          unobservableSource =
            LegacyProjectionSource
              (\_ -> pure (LegacyProjectionUnobservable "timeout" :: LegacyProjectionObservation Text))
      corrupt <-
        importLegacyProjection
          codecConfig
          4096
          repository
          corruptSource
          (normalTarget targetReads targetState)
          CheckpointProjection
      corrupt `shouldBe` Left (ProjectionImportSourceCorrupt CheckpointProjection "bad envelope")
      unobservable <-
        importLegacyProjection
          codecConfig
          4096
          repository
          unobservableSource
          (normalTarget targetReads targetState)
          CheckpointProjection
      unobservable
        `shouldBe` Left (ProjectionImportSourceUnobservable CheckpointProjection "timeout")
      let corruptTarget =
            ProjectionImportTarget
              { observeImportedProjection = \_ -> pure (ProjectionTargetCorrupt "bad target")
              , initializeImportedProjection = \_ _ ->
                  pure (ProjectionTargetWriteUnobservable "unreachable")
              }
          unobservableTarget =
            ProjectionImportTarget
              { observeImportedProjection = \_ -> pure (ProjectionTargetUnobservable "target timeout")
              , initializeImportedProjection = \_ _ ->
                  pure (ProjectionTargetWriteUnobservable "unreachable")
              }
      targetCorrupt <-
        importLegacyProjection
          codecConfig
          4096
          repository
          stableCheckpointSource
          corruptTarget
          CheckpointProjection
      targetCorrupt
        `shouldBe` Left (ProjectionImportTargetCorrupt CheckpointProjection "bad target")
      targetUnobservable <-
        importLegacyProjection
          codecConfig
          4096
          repository
          stableCheckpointSource
          unobservableTarget
          CheckpointProjection
      targetUnobservable
        `shouldBe` Left (ProjectionImportTargetUnobservable CheckpointProjection "target timeout")
      conflict <-
        importLegacyProjection
          codecConfig
          4096
          repository
          stableCheckpointSource
          (normalTarget targetReads targetState)
          CheckpointProjection
      conflict `shouldSatisfy` isTargetConflict
      readIORef migrationRevision `shouldReturn` 0

    it "rejects swapped Model-B coordinates before selecting an adapter" $ do
      let lease = coordinate "leases/account/region/resource"
          checkpoint = coordinate "pulumi-stack/aws-ses"
          target = coordinate "target-commit-intents/aws-ses"
          smtp = coordinate "smtp-commit/aws-ses"
      mkMigrationProjectionCoordinates lease checkpoint target smtp `shouldSatisfy` isRight
      mkMigrationProjectionCoordinates checkpoint lease target smtp
        `shouldBe` Left
          ( MigrationProjectionCoordinateWrongNamespace
              LeaseProjection
              "pulumi-stack/aws-ses"
          )
      mkMigrationProjectionCoordinates lease checkpoint target target
        `shouldBe` Left
          ( MigrationProjectionCoordinateWrongNamespace
              SmtpProjection
              "target-commit-intents/aws-ses"
          )

    it "lowers the closed projection selection to the exact Model-B initialize" $ do
      let coordinates = migrationCoordinates
          version = mustRight (mkModelBObjectVersion "projection-v1")
          sourceAdapter =
            ModelBCasAdapter
              { modelBObserve = \selected -> do
                  selected `shouldBe` migrationProjectionCoordinate coordinates CheckpointProjection
                  pure (ModelBObserved version checkpointBytes)
              , modelBCompareAndSwap = \_ -> pure (ModelBCasUnobservable "unused")
              }
      sourceObservation <-
        observeLegacyProjection
          (modelBLegacyProjectionSource sourceAdapter coordinates)
          CheckpointProjection
      sourceObservation `shouldBe` LegacyProjectionObserved version checkpointBytes
      requests <- newIORef []
      let targetAdapter =
            ModelBCasAdapter
              { modelBObserve = \_ -> pure ModelBMissing
              , modelBCompareAndSwap = \request -> do
                  modifyIORef' requests (request :)
                  pure (ModelBCasApplied version checkpointBytes)
              }
      written <-
        initializeImportedProjection
          (modelBProjectionImportTarget targetAdapter coordinates)
          CheckpointProjection
          checkpointBytes
      written `shouldBe` ProjectionTargetWriteApplied version
      observedRequests <- readIORef requests
      case observedRequests of
        [ModelBInitialize selected bytes] -> do
          selected `shouldBe` migrationProjectionCoordinate coordinates CheckpointProjection
          bytes `shouldBe` checkpointBytes
        _ -> expectationFailure "expected one exact Model-B initialization"

    it "uses the heterogeneous production lifetimes and real typed source codecs" $ do
      let version = mustRight (mkModelBObjectVersion "legacy-source-v1")
          legacyCoordinates =
            mustRight
              ( mkLegacyMigrationProjectionCoordinates
                  (coordinate "leases/account/region/resource")
                  chartCheckpointCoordinate
                  (coordinate "target-commit-intents/aws-ses")
                  (coordinate "smtp-commit/aws-ses")
              )
          adapters =
            LegacyProjectionAdapters
              { legacyLeaseProjectionAdapter =
                  observedAdapter
                    (coordinate "leases/account/region/resource")
                    version
                    activeLeaseProjection
              , legacyCheckpointProjectionAdapter =
                  observedAdapter chartCheckpointCoordinate version checkpointBytes
              , legacyTargetIntentProjectionAdapter =
                  observedAdapter
                    (coordinate "target-commit-intents/aws-ses")
                    version
                    targetProjection
              , legacySmtpProjectionAdapter =
                  observedAdapter
                    (coordinate "smtp-commit/aws-ses")
                    version
                    (mustRight (decodeSmtpCommittedProjection smtpBytes))
              }
          source = legacyProjectionSourceFromAdapters adapters legacyCoordinates
          expected =
            [ (LeaseProjection, encodeLeaseProjection activeLeaseProjection)
            , (CheckpointProjection, checkpointBytes)
            , (TargetIntentProjection, encodeTargetIntentProjection targetProjection)
            , (SmtpProjection, smtpBytes)
            ]
      mapM_
        ( \(projection, bytes) -> do
            observed <- observeLegacyProjection source projection
            observed `shouldBe` LegacyProjectionObserved version bytes
        )
        expected

    it "constructs the closed production aws-ses inventory at exact source and replacement coordinates" $ do
      production <-
        either (testFailure . show) pure $
          mkProductionProjectionImport
            authority
            replacementAuthority
            leaseKey
            defaultSesLeasePolicy
            registeredTargets
            4096
      let legacy = productionLegacyProjectionCoordinates production
          replacement = productionReplacementProjectionCoordinates production
          leaseName = "leases/123456789012/ca-central-1/aws-ses"
          checkpointName = "pulumi-stack/aws-ses"
          targetName = "target-commit-intents/123456789012/ca-central-1/aws-ses"
          smtpName = "smtp-commit/123456789012/ca-central-1/aws-ses"
          expectedNames =
            [leaseName, checkpointName, targetName, smtpName]
      fmap
        modelBObjectLogicalName
        [ legacyMigrationLeaseCoordinate legacy
        , legacyMigrationTargetIntentCoordinate legacy
        , legacyMigrationSmtpCoordinate legacy
        ]
        `shouldBe` [leaseName, targetName, smtpName]
      modelBObjectLogicalName (legacyMigrationCheckpointCoordinate legacy)
        `shouldBe` checkpointName
      fmap
        (modelBObjectLogicalName . migrationProjectionCoordinate replacement)
        [minBound .. maxBound]
        `shouldBe` expectedNames

    it "refuses malformed AWS identity, cross-scope, and non-aws-ses production construction" $ do
      let otherScope =
            mustRight
              ( mkLongLivedCheckpointAuthority
                  "other-control"
                  "replacement-state"
                  "lifecycle-v2"
                  "transit/prodbox-v2"
              )
          otherResource =
            mustRight (mkLeaseKey "123456789012" "ca-central-1" "other-stack")
          malformedAccount =
            mustRight (mkLeaseKey "1234" "ca-central-1" "aws-ses")
          malformedRegion =
            mustRight (mkLeaseKey "123456789012" "CA-CENTRAL-1" "aws-ses")
      case mkProductionProjectionImport
        authority
        replacementAuthority
        malformedAccount
        defaultSesLeasePolicy
        registeredTargets
        4096 of
        Left failure ->
          failure `shouldBe` ProductionProjectionImportAccountInvalid
        Right _ -> expectationFailure "expected malformed AWS account refusal"
      case mkProductionProjectionImport
        authority
        replacementAuthority
        malformedRegion
        defaultSesLeasePolicy
        registeredTargets
        4096 of
        Left failure ->
          failure `shouldBe` ProductionProjectionImportRegionInvalid
        Right _ -> expectationFailure "expected malformed AWS region refusal"
      case mkProductionProjectionImport
        authority
        otherScope
        leaseKey
        defaultSesLeasePolicy
        registeredTargets
        4096 of
        Left failure ->
          failure
            `shouldBe` ProductionProjectionImportScopeMismatch
              "home-control"
              "other-control"
        Right _ -> expectationFailure "expected cross-scope construction refusal"
      case mkProductionProjectionImport
        authority
        replacementAuthority
        otherResource
        defaultSesLeasePolicy
        registeredTargets
        4096 of
        Left failure ->
          failure
            `shouldBe` ProductionProjectionImportResourceUnsupported "other-stack"
        Right _ -> expectationFailure "expected non-aws-ses construction refusal"

    it "records and completes import evidence through one aggregate CAS with response-loss readback" $ do
      aggregateRef <- newIORef openedMigratingAggregate
      revisionRef <- newIORef (0 :: Word)
      let applicator =
            authorityAdmissionMigrationImportApplicator
              (responseLostAuthorityRepository aggregateRef revisionRef)
          projections = [minBound .. maxBound] :: [MigrationProjection]
      mapM_
        ( \projection -> do
            applied <-
              runMigrationImportCommandApplicator
                applicator
                (RecordProjectionImport projection ProjectionMissing)
            applied `shouldSatisfy` hasImportDecision MigrationImportAccepted
        )
        projections
      completed <-
        runMigrationImportCommandApplicator applicator CompleteProjectionImports
      completed `shouldSatisfy` hasImportDecision MigrationImportAccepted
      replayed <-
        runMigrationImportCommandApplicator
          applicator
          (RecordProjectionImport LeaseProjection ProjectionMissing)
      replayed `shouldSatisfy` hasImportDecision MigrationImportAlreadyApplied
      readIORef revisionRef `shouldReturn` 5
      aggregate <- readIORef aggregateRef
      case authorityAggregateMigration aggregate of
        AuthorityCleanInstall ->
          expectationFailure "expected migration-controlled aggregate readback"
        AuthorityMigrationControlled migration ->
          Map.size (migrationProjectionImports migration) `shouldBe` 4

    it "preserves aggregate admission refusal instead of relabelling it as I/O failure" $ do
      let command = RecordProjectionImport LeaseProjection ProjectionMissing
          frozenApplicator =
            authorityAdmissionMigrationImportApplicator
              (readOnlyAuthorityRepository migratingFrozenAggregate)
          cleanApplicator =
            authorityAdmissionMigrationImportApplicator
              (readOnlyAuthorityRepository openedCleanAggregate)
      runMigrationImportCommandApplicator frozenApplicator command
        `shouldReturn` Left
          (MigrationImportAuthorityRefused AuthorityMigrationBeforeGenesis)
      runMigrationImportCommandApplicator cleanApplicator command
        `shouldReturn` Left
          (MigrationImportAuthorityRefused AuthorityMigrationNotStarted)

    it "requires two complete shadow passes with stable source and target revisions" $ do
      stable <-
        shadowCompareLegacyProjections
          codecConfig
          stableMixedSource
          stableMixedTarget
      proof <- either (testFailure . show) pure stable
      Map.size (projectionShadowEvidence proof) `shouldBe` 4
      Map.lookup CheckpointProjection (projectionShadowEvidence proof)
        `shouldSatisfy` isLegacyEvidenceMaybe

      revision <- newIORef (0 :: Word)
      let observeMoving projection = case projection of
            CheckpointProjection -> do
              next <- atomicModifyIORef' revision (\current -> (current + 1, current + 1))
              pure (LegacyProjectionObserved next checkpointBytes)
            _ -> pure LegacyProjectionMissing
          movingSource = LegacyProjectionSource observeMoving
      moved <-
        shadowCompareLegacyProjections
          codecConfig
          movingSource
          stableMixedTarget
      moved `shouldBe` Left (ProjectionImportShadowChanged CheckpointProjection)

codecConfig :: ProjectionImportCodecConfig
codecConfig =
  mustRight
    (mkProjectionImportCodecConfig defaultSesLeasePolicy registeredTargets 4096)

checkpointBytes :: ByteString
checkpointBytes = "{ \"deployment\" : { \"resources\" : [] }, \"version\" : 3 }"

targetProjection :: TargetIntentProjection
targetProjection = emptyTargetIntentProjection registeredTargets

smtpBytes :: ByteString
smtpBytes =
  mustRight
    ( encodeSmtpCommittedProjection
        ( mkCommittedSmtpCredential
            (mustRight (mkSmtpAccessKeyId "AKIAPROJECTIONIMPORT1"))
            (mustRight (mkCredentialGeneration 1))
            (sha256TargetValueDigest "smtp-projection")
            (Just "sealed-smtp-material")
        )
    )

authority :: LongLivedCheckpointAuthority
authority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "prodbox-state"
        "lifecycle"
        "transit/prodbox"
    )

replacementAuthority :: LongLivedCheckpointAuthority
replacementAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "prodbox-authority-state"
        "lifecycle-v2"
        "transit/lifecycle-authority"
    )

targetSink :: TargetClusterSecretSink
targetSink =
  mustRight
    ( mkTargetClusterSecretSink
        "home"
        "secret"
        "keycloak/smtp"
    )

registeredTargets :: RegisteredTargetSet
registeredTargets = mustRight (mkRegisteredTargetSet 1 [targetSink])

leaseKey :: LeaseKey
leaseKey = mustRight (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

leaseOwner :: OwnerNonce
leaseOwner = mustRight (mkOwnerNonce "projection-import-owner")

activeLeaseProjection :: LeaseProjection
activeLeaseProjection =
  case decideLeaseAcquire
    defaultSesLeasePolicy
    (authorityTimeFromMicros 1)
    ( mustRight
        (beginLeaseAcquire defaultSesLeasePolicy authority leaseKey leaseOwner (authorityTimeFromMicros 1))
    )
    Nothing
    ModelBMissing of
    LeaseAcquireCompareAndSwap (ModelBInitialize _ projection) -> projection
    other -> error ("expected first lease projection, got " ++ show other)

activeLeaseGrant :: LeaseGrant
activeLeaseGrant = case leaseProjectionActiveGrant activeLeaseProjection of
  Just grant -> grant
  Nothing -> error "expected active lease grant"

releasedLeaseProjection :: LeaseProjection
releasedLeaseProjection =
  case decideLeaseRelease
    (authorityTimeFromMicros 2)
    (mustRight (leaseObjectCoordinate authority leaseKey))
    activeLeaseGrant
    ( ModelBObserved
        (mustRight (mkModelBObjectVersion "lease-v1"))
        activeLeaseProjection
    ) of
    LeaseReleaseCompareAndSwap (ModelBReplace _ _ projection) -> projection
    other -> error ("expected released lease projection, got " ++ show other)

stagedTargetProjection :: TargetIntentProjection
stagedTargetProjection =
  case decidePrepareTargetCommit
    registeredTargets
    (mustRight (mkTargetIntentCoordinate authority leaseKey))
    (authorityTimeFromMicros 3)
    (authorityTimeFromMicros 100)
    leasePermit
    targetSink
    (mustRight (mkCredentialGeneration 1))
    (sha256TargetValueDigest "target-intent")
    ModelBMissing of
    TargetCommitPrepareCompareAndSwap (ModelBInitializeGuarded _ _ projection) _ -> projection
    other -> error ("expected staged target projection, got " ++ show other)

leasePermit :: FencedCommitPermit
leasePermit =
  case decideFencedCommit
    (authorityTimeFromMicros 3)
    activeLeaseGrant
    ( ModelBObserved
        (mustRight (mkModelBObjectVersion "lease-v1"))
        activeLeaseProjection
    ) of
    LeaseCommitAuthorized permit -> permit
    other -> error ("expected lease commit permit, got " ++ show other)

stableCheckpointSource :: LegacyProjectionSource IO Text
stableCheckpointSource =
  LegacyProjectionSource
    (\_ -> pure (LegacyProjectionObserved "legacy-v1" checkpointBytes))

sourceSequence
  :: IORef [LegacyProjectionObservation Text]
  -> LegacyProjectionSource IO Text
sourceSequence observations =
  LegacyProjectionSource $ \_ -> atomicModifyIORef' observations nextObservation
 where
  nextObservation remaining = case remaining of
    [] -> ([], LegacyProjectionUnobservable "fixture exhausted")
    [lastObservation] -> ([lastObservation], lastObservation)
    next : rest -> (rest, next)

normalTarget
  :: IORef Int
  -> IORef (Maybe (Word, ByteString))
  -> ProjectionImportTarget IO Word
normalTarget readCount stateRef =
  ProjectionImportTarget
    { observeImportedProjection = \_ -> do
        modifyIORef' readCount (+ 1)
        state <- readIORef stateRef
        pure $ case state of
          Nothing -> ProjectionTargetMissing
          Just (revision, bytes) -> ProjectionTargetObserved revision bytes
    , initializeImportedProjection = \_ bytes -> do
        current <- readIORef stateRef
        case current of
          Nothing -> do
            writeIORef stateRef (Just (1, bytes))
            pure (ProjectionTargetWriteApplied 1)
          Just (revision, existing) ->
            pure (ProjectionTargetWriteConflict (ProjectionTargetObserved revision existing))
    }

responseLostTarget
  :: IORef Int
  -> IORef (Maybe (Word, ByteString))
  -> ProjectionImportTarget IO Word
responseLostTarget readCount stateRef =
  (normalTarget readCount stateRef)
    { initializeImportedProjection = \_ bytes -> do
        writeIORef stateRef (Just (1, bytes))
        pure (ProjectionTargetWriteEndpointUnready "response lost")
    }

missingTarget :: IORef Int -> ProjectionImportTarget IO Word
missingTarget readCount =
  ProjectionImportTarget
    { observeImportedProjection = \_ -> do
        modifyIORef' readCount (+ 1)
        pure ProjectionTargetMissing
    , initializeImportedProjection = \_ _ ->
        pure (ProjectionTargetWriteUnobservable "unexpected initialize")
    }

inMemoryMigrationRepository
  :: IORef (Maybe (StoredMigration Word))
  -> IORef Word
  -> MigrationRepository IO Word
inMemoryMigrationRepository stateRef revisionRef =
  MigrationRepository
    { readMigrationState = Right <$> readIORef stateRef
    , compareAndSwapMigrationState = \expected bytes -> do
        current <- readIORef stateRef
        if fmap storedMigrationRevision current /= expected
          then pure (Right False)
          else do
            revision <- atomicModifyIORef' revisionRef (\value -> (value + 1, value + 1))
            writeIORef stateRef (Just (StoredMigration revision bytes))
            pure (Right True)
    }

responseLostAuthorityRepository
  :: IORef AuthorityAdmissionAggregate
  -> IORef Word
  -> AuthorityAdmissionRepository IO Word
responseLostAuthorityRepository stateRef revisionRef =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        state <- readIORef stateRef
        revision <- readIORef revisionRef
        pure
          ( Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = revision
                , authorityAdmissionSnapshotState = state
                }
          )
    , compareAndSwapAuthorityAdmission = \expected next -> do
        current <- readIORef revisionRef
        if current /= expected
          then pure (Left "authority admission exact-revision conflict")
          else do
            writeIORef stateRef next
            writeIORef revisionRef (current + 1)
            pure (Left "authority admission response lost after apply")
    }

readOnlyAuthorityRepository
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionRepository IO Word
readOnlyAuthorityRepository aggregate =
  AuthorityAdmissionRepository
    { readAuthorityAdmission =
        pure
          ( Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = 0
                , authorityAdmissionSnapshotState = aggregate
                }
          )
    , compareAndSwapAuthorityAdmission = \_ _ ->
        pure (Left "read-only authority admission fixture")
    }

migratingFrozenAggregate :: AuthorityAdmissionAggregate
migratingFrozenAggregate = mustRight (initialMigratingAuthority 4 8)

openedMigratingAggregate :: AuthorityAdmissionAggregate
openedMigratingAggregate = openAdmissionAggregate migratingFrozenAggregate

openedCleanAggregate :: AuthorityAdmissionAggregate
openedCleanAggregate =
  openAdmissionAggregate (mustRight (initialCleanInstallAuthority 4 8))

openAdmissionAggregate
  :: AuthorityAdmissionAggregate
  -> AuthorityAdmissionAggregate
openAdmissionAggregate initial =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    initial
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "projection-import-genesis" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

coordinate :: Text -> ModelBObjectCoordinate 'ClusterRetained
coordinate name = mustRight (mkClusterRetainedCoordinate authority name)

chartCheckpointCoordinate :: ModelBObjectCoordinate 'ChartLifetime
chartCheckpointCoordinate =
  mustRight (mkChartLifetimeCoordinate authority "pulumi-stack/aws-ses")

observedAdapter
  :: ModelBObjectCoordinate lifetime
  -> ModelBObjectVersion
  -> value
  -> ModelBCasAdapter lifetime IO value
observedAdapter expected version value =
  ModelBCasAdapter
    { modelBObserve = \selected -> do
        selected `shouldBe` expected
        pure (ModelBObserved version value)
    , modelBCompareAndSwap = \_ -> pure (ModelBCasUnobservable "unused")
    }

stableMixedSource :: LegacyProjectionSource IO Word
stableMixedSource =
  LegacyProjectionSource $ \projection ->
    pure $ case projection of
      CheckpointProjection -> LegacyProjectionObserved 1 checkpointBytes
      _ -> LegacyProjectionMissing

stableMixedTarget :: ProjectionImportTarget IO Word
stableMixedTarget =
  ProjectionImportTarget
    { observeImportedProjection = \projection ->
        pure $ case projection of
          CheckpointProjection -> ProjectionTargetObserved 1 checkpointBytes
          _ -> ProjectionTargetMissing
    , initializeImportedProjection = \_ _ ->
        pure (ProjectionTargetWriteUnobservable "unexpected initialize")
    }

migrationCoordinates :: MigrationProjectionCoordinates
migrationCoordinates =
  mustRight
    ( mkMigrationProjectionCoordinates
        (coordinate "leases/account/region/resource")
        (coordinate "pulumi-stack/aws-ses")
        (coordinate "target-commit-intents/aws-ses")
        (coordinate "smtp-commit/aws-ses")
    )

isSuccessfulImport :: Either ProjectionImportFailure ProjectionImportResult -> Bool
isSuccessfulImport result = case result of
  Right imported ->
    appliedMigrationImportDecision (projectionImportStateResult imported)
      == MigrationImportAccepted
  Left _ -> False

hasImportDecision
  :: MigrationImportDecision
  -> Either MigrationImportApplicationError MigrationImportApplyResult
  -> Bool
hasImportDecision expected result = case result of
  Right applied -> appliedMigrationImportDecision applied == expected
  Left _ -> False

isLegacyEvidence :: MigrationProjectionImport -> Bool
isLegacyEvidence evidence = case evidence of
  ProjectionLegacy _ -> True
  _ -> False

isLegacyEvidenceMaybe :: Maybe MigrationProjectionImport -> Bool
isLegacyEvidenceMaybe = maybe False isLegacyEvidence

isReleasedEvidence :: MigrationProjectionImport -> Bool
isReleasedEvidence evidence = case evidence of
  ProjectionReleasedPredecessor _ -> True
  _ -> False

isStagedEvidence :: MigrationProjectionImport -> Bool
isStagedEvidence evidence = case evidence of
  ProjectionStaged _ _ -> True
  _ -> False

isTargetConflict :: Either ProjectionImportFailure ProjectionImportResult -> Bool
isTargetConflict result = case result of
  Left ProjectionImportTargetConflict {} -> True
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("invalid projection-import fixture: " ++ show err)

testFailure :: String -> IO value
testFailure detail = expectationFailure detail >> error detail
