{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module LifecycleAuthorityMigration (lifecycleAuthorityMigrationSuite) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Word (Word8)
import Prodbox.ControlPlane.AuthenticatedTransport (mkRouteTrustRegistry)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyName
  , controlPlaneSigningKeyRefFor
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService)
  , callerPrincipalCode
  )
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStoreConfigError (..)
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( mkSigningKeyGeneration
  , mkTrustedRequestKey
  )
import Prodbox.ControlPlane.Route (controlPlaneRoutePath, routesForRole)
import Prodbox.ControlPlane.Runtime
  ( AuthorityBackupStoreWire (..)
  , ControlPlaneAuthenticationWire (..)
  , ControlPlaneConfig (..)
  , ControlPlaneConfigError (..)
  , ControlPlaneRoleStore (..)
  , ControlPlaneTrustedCallerWire (..)
  , PrimaryStoreWire (..)
  , TlsRetentionStoreWire (..)
  , registeredClientTableFromTrustRegistry
  , validateControlPlaneConfig
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( clientPrincipalForCaller
  , registeredClientReservationCount
  , registeredClientTableSize
  )
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.Authority.MigrationInterpreter
import Prodbox.Lifecycle.CheckpointAuthority qualified as Checkpoint
import Prodbox.Runtime.Role
  ( RuntimeRole (..)
  , runtimeRoleName
  )
import TestSupport

lifecycleAuthorityMigrationSuite :: SuiteBuilder ()
lifecycleAuthorityMigrationSuite =
  describe "Lifecycle Authority single-writer migration" $ do
    it "never exposes two active writers" $
      fmap activeWriter (scanl apply initialMigrationState migrationCommands)
        `shouldSatisfy` all (`elem` [Nothing, Just LegacyWriter, Just ReplacementWriter])
    it "refuses activation until every binding is prepared" $ do
      let frozen = apply (apply initialMigrationState (VerifyShadow digest)) (FreezeLegacy digest)
      snd (stepMigration frozen (ActivateReplacement epoch))
        `shouldBe` MigrationRefused
          (ActivationBindingsMissing (Set.fromList [minBound .. maxBound]))
    it "activates atomically after the complete preparation set" $
      activeWriter (foldl apply initialMigrationState migrationCommands)
        `shouldBe` Just ReplacementWriter
    it "makes direct rollback unrepresentable after activation" $ do
      let final = foldl apply initialMigrationState migrationCommands
      stepMigration final RequestLegacyRollback
        `shouldBe` (final, MigrationRefused LegacyRollbackForbidden)
    it "makes exact replay idempotent and divergent shadow state terminal" $ do
      let verified = apply initialMigrationState (VerifyShadow digest)
      decideMigration verified (VerifyShadow digest) `shouldBe` MigrationAlreadyApplied
      decideMigration verified (VerifyShadow (fromJust (mkMigrationDigest "other")))
        `shouldBe` MigrationRefused ShadowDigestConflict
    it "rejects empty, control-bearing, and over-bound migration digests" $ do
      mkMigrationDigest "" `shouldBe` Nothing
      mkMigrationDigest "bad\nbinding" `shouldBe` Nothing
      mkMigrationDigest (Text.replicate 129 "a") `shouldBe` Nothing
      mkMigrationDigest (Text.replicate 128 "a") `shouldSatisfy` (/= Nothing)
    it "imports the finite missing, legacy, staged, and released-predecessor matrix" $ do
      let (incomplete, incompleteDecision) =
            stepMigrationImport initialMigrationState CompleteProjectionImports
      incomplete `shouldBe` initialMigrationState
      incompleteDecision
        `shouldBe` MigrationImportRefused (MigrationImportsMissing requiredMigrationProjections)
      let importStates = scanl applyImport initialMigrationState projectionImportCommands
          ready = last importStates
      fmap activeWriter importStates `shouldSatisfy` all (== Just LegacyWriter)
      migrationProjectionImports ready `shouldBe` projectionImportMatrix
      fmap (decodeMigrationImportCommand 4096 . encodeMigrationImportCommand) projectionImportCommands
        `shouldBe` fmap Right projectionImportCommands
      let (replayed, replayDecision) =
            stepMigrationImport ready (RecordProjectionImport SmtpProjection ProjectionMissing)
          (conflicted, conflictDecision) =
            stepMigrationImport ready (RecordProjectionImport SmtpProjection (ProjectionLegacy digest))
      replayed `shouldBe` ready
      replayDecision `shouldBe` MigrationImportAlreadyApplied
      conflicted `shouldBe` ready
      conflictDecision
        `shouldBe` MigrationImportRefused (MigrationImportConflict SmtpProjection)
    it "keeps one writer through imported cutover and forward epoch recovery" $ do
      let importedReady = foldl applyImport initialMigrationState projectionImportCommands
          firstStates = scanl apply importedReady migrationCommands
          firstActive = last firstStates
          begin = BeginForwardMigration digest nextEpoch
          (forwardShadow, beginDecision) = stepForwardMigration firstActive begin
          forwardCommands =
            [FreezeLegacy digest]
              ++ fmap PrepareBinding [minBound .. maxBound]
              ++ [ActivateReplacement nextEpoch]
          forwardStates = scanl apply forwardShadow forwardCommands
          nextActive = last forwardStates
      fmap activeWriter firstStates
        `shouldSatisfy` all (`elem` [Nothing, Just LegacyWriter, Just ReplacementWriter])
      beginDecision `shouldBe` ForwardMigrationAccepted
      activeWriter forwardShadow `shouldBe` Just ReplacementWriter
      migrationPredecessor forwardShadow
        `shouldBe` ReleasedReplacementPredecessor epoch
      fmap activeWriter forwardStates
        `shouldSatisfy` all (`elem` [Nothing, Just ReplacementWriter])
      activeWriter nextActive `shouldBe` Just ReplacementWriter
      migrationPredecessor nextActive
        `shouldBe` ReleasedReplacementPredecessor nextEpoch
      stepForwardMigration nextActive begin
        `shouldBe` (nextActive, ForwardMigrationAlreadyApplied)
      stepMigration nextActive RequestLegacyRollback
        `shouldBe` (nextActive, MigrationRefused LegacyRollbackForbidden)
    it "projects the exact active Lifecycle Authority epoch for external writers" $ do
      let importedReady = foldl applyImport initialMigrationState projectionImportCommands
          firstActive = foldl apply importedReady migrationCommands
          (forwardShadow, _) =
            stepForwardMigration firstActive (BeginForwardMigration digest nextEpoch)
          forwardFrozen = apply forwardShadow (FreezeLegacy digest)
          nextActive =
            foldl
              apply
              forwardFrozen
              (fmap PrepareBinding [minBound .. maxBound] ++ [ActivateReplacement nextEpoch])
      migrationAuthorityStatus initialMigrationState `shouldBe` MigrationLegacyWriterActive
      migrationAuthorityStatus firstActive
        `shouldBe` MigrationReplacementWriterActive epoch
      migrationEpochValue epoch `shouldBe` 2
      migrationAuthorityStatus forwardShadow
        `shouldBe` MigrationReplacementWriterActive epoch
      migrationAuthorityStatus forwardFrozen `shouldBe` MigrationWritersQuiesced
      migrationAuthorityStatus nextActive
        `shouldBe` MigrationReplacementWriterActive nextEpoch
    it "requires a declared forward target strictly above the released predecessor" $ do
      let firstActive = foldl apply initialMigrationState migrationCommands
          sameEpoch = BeginForwardMigration digest epoch
          (forwardShadow, _) = stepForwardMigration firstActive (BeginForwardMigration digest nextEpoch)
          frozen = apply forwardShadow (FreezeLegacy digest)
          prepared = foldl apply frozen (fmap PrepareBinding [minBound .. maxBound])
      stepForwardMigration firstActive sameEpoch
        `shouldBe` (firstActive, ForwardMigrationRefused ForwardMigrationEpochMustAdvance)
      snd (stepForwardMigration firstActive (BeginForwardMigration otherDigest predecessorEpoch))
        `shouldBe` ForwardMigrationRefused ForwardMigrationEpochMustAdvance
      snd (stepMigration firstActive (ActivateReplacement nextEpoch))
        `shouldBe` MigrationRefused ActivationBeforeFreeze
      snd (stepMigration prepared (ActivateReplacement epoch))
        `shouldBe` MigrationRefused EpochMustAdvance
      snd (stepMigration prepared (ActivateReplacement futureEpoch))
        `shouldBe` MigrationRefused EpochMustAdvance
      snd (stepMigration prepared (ActivateReplacement nextEpoch))
        `shouldSatisfy` isMigrationAcceptedDecision
      decodeMigrationForwardCommand
        4096
        (encodeMigrationForwardCommand (BeginForwardMigration digest nextEpoch))
        `shouldBe` Right (BeginForwardMigration digest nextEpoch)
    it "round-trips the activated state through bounded canonical CBOR" $ do
      let final = foldl apply initialMigrationState migrationCommands
          encoded = encodeMigrationState final
      decodeMigrationState 4096 encoded `shouldBe` Right final
      decodeMigrationState 1 encoded `shouldBe` Left MigrationEnvelopeTooLarge
      decodeMigrationState 4096 (LazyByteString.pack [255])
        `shouldBe` Left MigrationEnvelopeInvalid
    it "decodes the frozen v1 missing-state fixture and emits v2 on the next write" $ do
      let v1Missing = LazyByteString.pack [131, 0, 1, 129, 0]
      decodeMigrationState 4096 v1Missing `shouldBe` Right initialMigrationState
      encodeMigrationState initialMigrationState `shouldSatisfy` (/= v1Missing)
    it "semantically rejects canonical states and commands containing forged opaque values" $ do
      let active = foldl apply initialMigrationState migrationCommands
          verified = apply initialMigrationState (VerifyShadow digest)
          invalidStateEpoch = replaceLastByte 0 (encodeMigrationState active)
          invalidStateDigest = replaceLastByte 10 (encodeMigrationState verified)
          invalidCommandEpoch = replaceLastByte 0 (encodeMigrationCommand (ActivateReplacement epoch))
          invalidCommandDigest = replaceLastByte 10 (encodeMigrationCommand (VerifyShadow digest))
          invalidImportDigest =
            replaceLastByte
              10
              (encodeMigrationImportCommand (RecordProjectionImport LeaseProjection (ProjectionLegacy digest)))
          invalidForwardEpoch =
            replaceLastByte 0 (encodeMigrationForwardCommand (BeginForwardMigration digest nextEpoch))
      decodeMigrationState 4096 invalidStateEpoch `shouldBe` Left MigrationEnvelopeInvalid
      decodeMigrationState 4096 invalidStateDigest `shouldBe` Left MigrationEnvelopeInvalid
      decodeMigrationCommand 4096 invalidCommandEpoch `shouldBe` Left MigrationEnvelopeInvalid
      decodeMigrationCommand 4096 invalidCommandDigest `shouldBe` Left MigrationEnvelopeInvalid
      decodeMigrationImportCommand 4096 invalidImportDigest `shouldBe` Left MigrationEnvelopeInvalid
      decodeMigrationForwardCommand 4096 invalidForwardEpoch `shouldBe` Left MigrationEnvelopeInvalid
    it "round-trips every durable migration prefix for restart" $ do
      let states = scanl apply initialMigrationState migrationCommands
      fmap (decodeMigrationState 4096 . encodeMigrationState) states
        `shouldBe` fmap Right states
    it "rejects raw pre-envelope state bytes instead of guessing a schema" $ do
      decodeMigrationState 4096 (LazyByteString.pack [129, 0])
        `shouldBe` Left MigrationEnvelopeInvalid
    it "persists each accepted command through exact-revision CAS" $ do
      stateRef <- newIORef Nothing
      revisionRef <- newIORef (0 :: Word)
      let repository = inMemoryRepository stateRef revisionRef False
      results <- traverse (applyMigrationCommand 4096 repository) migrationCommands
      results `shouldSatisfy` all isAccepted
      stored <- readIORef stateRef
      fmap (decodeMigrationState 4096 . storedMigrationBytes) stored
        `shouldBe` Just (Right (foldl apply initialMigrationState migrationCommands))
    it "does not write idempotent replays or refused commands" $ do
      stateRef <- newIORef Nothing
      revisionRef <- newIORef (0 :: Word)
      let repository = inMemoryRepository stateRef revisionRef False
      first <- applyMigrationCommand 4096 repository (VerifyShadow digest)
      replay <- applyMigrationCommand 4096 repository (VerifyShadow digest)
      refused <- applyMigrationCommand 4096 repository RequestLegacyRollback
      first `shouldSatisfy` isAccepted
      replay `shouldSatisfy` isAlreadyApplied
      refused `shouldSatisfy` isRefused
      readIORef revisionRef `shouldReturn` 1
    it "persists imported projection evidence once and never overwrites a conflict" $ do
      stateRef <- newIORef Nothing
      revisionRef <- newIORef (0 :: Word)
      let repository = inMemoryRepository stateRef revisionRef False
      imported <- traverse (applyMigrationImportCommand 4096 repository) projectionImportCommands
      imported `shouldSatisfy` all isImportAccepted
      replay <-
        applyMigrationImportCommand
          4096
          repository
          (RecordProjectionImport SmtpProjection ProjectionMissing)
      conflict <-
        applyMigrationImportCommand
          4096
          repository
          (RecordProjectionImport SmtpProjection (ProjectionLegacy digest))
      replay `shouldSatisfy` isImportAlreadyApplied
      conflict `shouldSatisfy` isImportRefused
      readIORef revisionRef `shouldReturn` fromIntegral (length projectionImportCommands)
    it "fails closed on corrupt state and a lost CAS race" $ do
      corruptRef <-
        newIORef
          (Just (StoredMigration (1 :: Word) (LazyByteString.pack [255])))
      revisionRef <- newIORef (1 :: Word)
      corrupt <-
        applyMigrationCommand
          4096
          (inMemoryRepository corruptRef revisionRef False)
          (VerifyShadow digest)
      corrupt
        `shouldBe` Left (MigrationDecodeFailed MigrationEnvelopeInvalid)
      stateRef <- newIORef Nothing
      concurrent <-
        applyMigrationCommand
          4096
          (inMemoryRepository stateRef revisionRef True)
          (VerifyShadow digest)
      concurrent `shouldBe` Left MigrationConcurrentWrite
    it "resumes safely when activation is interrupted before or after the epoch CAS" $ do
      let importedReady = foldl applyImport initialMigrationState projectionImportCommands
          prepared =
            foldl
              apply
              importedReady
              ( [VerifyShadow digest, FreezeLegacy digest]
                  ++ fmap PrepareBinding [minBound .. maxBound]
              )
          stored revision = Just (StoredMigration revision (encodeMigrationState prepared))
      beforeStateRef <- newIORef (stored (10 :: Word))
      beforeRevisionRef <- newIORef (10 :: Word)
      beforeFailureRef <- newIORef True
      let beforeRepository =
            interruptBeforeWriteRepository beforeStateRef beforeRevisionRef beforeFailureRef
      interruptedBefore <- applyMigrationCommand 4096 beforeRepository (ActivateReplacement epoch)
      interruptedBefore `shouldBe` Left (MigrationWriteFailed "interrupted-before-epoch")
      readIORef beforeRevisionRef `shouldReturn` 10
      resumedBefore <- applyMigrationCommand 4096 beforeRepository (ActivateReplacement epoch)
      resumedBefore `shouldSatisfy` isAccepted
      readIORef beforeRevisionRef `shouldReturn` 11

      afterStateRef <- newIORef (stored (20 :: Word))
      afterRevisionRef <- newIORef (20 :: Word)
      afterFailureRef <- newIORef True
      let afterRepository =
            interruptAfterWriteRepository afterStateRef afterRevisionRef afterFailureRef
      interruptedAfter <- applyMigrationCommand 4096 afterRepository (ActivateReplacement epoch)
      interruptedAfter `shouldBe` Left (MigrationWriteFailed "interrupted-after-epoch")
      readIORef afterRevisionRef `shouldReturn` 21
      resumedAfter <- applyMigrationCommand 4096 afterRepository (ActivateReplacement epoch)
      resumedAfter `shouldSatisfy` isAlreadyApplied
      readIORef afterRevisionRef `shouldReturn` 21
    it "binds migration persistence to the retained Model-B coordinate" $ do
      requests <- newIORef []
      let version = mustRight (Checkpoint.mkModelBObjectVersion "migration-v1")
          adapter =
            Checkpoint.ModelBCasAdapter
              { Checkpoint.modelBObserve =
                  \_ -> pure Checkpoint.ModelBMissing
              , Checkpoint.modelBCompareAndSwap =
                  \request -> do
                    modifyIORef' requests (request :)
                    pure (Checkpoint.ModelBCasApplied version (requestState request))
              }
          repository = modelBMigrationRepository adapter retainedMigrationCoordinate
      result <- applyMigrationCommand 4096 repository (VerifyShadow digest)
      result `shouldSatisfy` isAccepted
      observedRequests <- readIORef requests
      case observedRequests of
        [Checkpoint.ModelBInitialize coordinate state] -> do
          coordinate `shouldBe` retainedMigrationCoordinate
          state `shouldBe` apply initialMigrationState (VerifyShadow digest)
        _ -> expectationFailure "expected one retained Model-B initialization"
    it "uses the bounded versioned migration codec at the Model-B boundary" $ do
      let codec = migrationStateCodec 4096
          final = foldl apply initialMigrationState migrationCommands
      encoded <- either testFailure pure (Checkpoint.encodeModelBValue codec final)
      Checkpoint.decodeModelBValue codec encoded `shouldBe` Right final
      Checkpoint.decodeModelBValue (migrationStateCodec 1) encoded
        `shouldBe` Left "MigrationEnvelopeTooLarge"
    it "validates schema-v7 closed role stores and rejects cross-role substitution" $ do
      let validConfigs =
            [
              ( LifecycleAuthorityRuntime
              , configFor LifecycleAuthorityRuntime 7 (RoleStorePrimary primaryStore)
              )
            , (ProviderWorkerRuntime, configFor ProviderWorkerRuntime 7 RoleStoreProviderWorker)
            ,
              ( AuthorityBackupRuntime
              , configFor AuthorityBackupRuntime 7 (RoleStoreAuthorityBackup backupStore)
              )
            ,
              ( TlsRetentionRuntime
              , configFor TlsRetentionRuntime 7 (RoleStoreTlsRetention tlsStore)
              )
            , (TargetSecretAgentRuntime, configFor TargetSecretAgentRuntime 7 RoleStoreTargetSecretAgent)
            ]
      mapM_
        (\(role, config) -> validateControlPlaneConfig role config `shouldSatisfy` isRight)
        validConfigs
      validateControlPlaneConfig
        AuthorityBackupRuntime
        (configFor AuthorityBackupRuntime 7 (RoleStoreTlsRetention tlsStore))
        `shouldFailWith` ControlPlaneConfigStoreRoleMismatch
      validateControlPlaneConfig
        TlsRetentionRuntime
        (configFor TlsRetentionRuntime 7 (RoleStoreAuthorityBackup backupStore))
        `shouldFailWith` ControlPlaneConfigStoreRoleMismatch
      validateControlPlaneConfig
        LifecycleAuthorityRuntime
        (configFor LifecycleAuthorityRuntime 3 (RoleStorePrimary primaryStore))
        `shouldFailWith` ControlPlaneConfigVersionUnsupported
      validateControlPlaneConfig
        LifecycleAuthorityRuntime
        ( (configFor LifecycleAuthorityRuntime 7 (RoleStorePrimary primaryStore))
            { runtime_role = "gateway-runtime"
            }
        )
        `shouldFailWith` ControlPlaneConfigRoleMismatch
      validateControlPlaneConfig
        LifecycleAuthorityRuntime
        ( (configFor LifecycleAuthorityRuntime 7 (RoleStorePrimary primaryStore))
            { cluster_id = ""
            }
        )
        `shouldFailWith` ControlPlaneConfigAuthorityStoreInvalid InClusterAuthorityClusterIdEmpty
    it "derives registered operation clients from the authenticated submit-route trust SSoT" $ do
      let generation = mustRight (mkSigningKeyGeneration 7)
          trusted =
            mustRight
              ( mkTrustedRequestKey
                  CallerOperatorCli
                  generation
                  (ByteString.replicate 32 1)
              )
          registry =
            mustRight
              ( mkRouteTrustRegistry
                  LifecycleAuthorityRuntime
                  1
                  [(route, trusted) | route <- routesForRole LifecycleAuthorityRuntime]
              )
          clients = mustRight (registeredClientTableFromTrustRegistry registry)
      registeredClientTableSize clients `shouldBe` 1
      registeredClientReservationCount
        (clientPrincipalForCaller CallerOperatorCli)
        clients
        `shouldBe` Just 0
 where
  digest = fromJust (mkMigrationDigest "fixture-v1")
  otherDigest = fromJust (mkMigrationDigest "fixture-v2")
  predecessorEpoch = fromJust (mkMigrationEpoch 1)
  epoch = fromJust (mkMigrationEpoch 2)
  nextEpoch = fromJust (mkMigrationEpoch 3)
  futureEpoch = fromJust (mkMigrationEpoch 4)
  endpoint = "http://minio.prodbox.svc.cluster.local:9000"
  bucket = "prodbox"
  primaryStore = PrimaryStoreWire endpoint bucket
  backupStore =
    AuthorityBackupStoreWire
      ("https://s3." <> (fixtureAwsRegion FixtureCaCentral1) <> ".amazonaws.com")
      (fixtureAwsRegion FixtureCaCentral1)
      "prodbox-retained"
      "authority-backup-store/home"
  tlsStore =
    TlsRetentionStoreWire
      ("https://s3." <> (fixtureAwsRegion FixtureCaCentral1) <> ".amazonaws.com")
      (fixtureAwsRegion FixtureCaCentral1)
      "prodbox-retained"
      "home-local"
      "test.example.com"
      "public-edge-tls/home-local/test.example.com"
  configFor role version store =
    ControlPlaneConfig
      { schema_version = version
      , runtime_role = Text.pack (runtimeRoleName role)
      , vault_address = "http://vault.vault.svc.cluster.local:8200"
      , vault_auth_path = "kubernetes"
      , vault_role = Text.pack (runtimeRoleName role)
      , service_account_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      , cluster_id = "home"
      , target_agent_identity =
          "home@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      , role_store = store
      , request_authentication =
          ControlPlaneAuthenticationWire
            { maximum_trusted_callers_per_route =
                fromIntegral
                  (maximum (1 : fmap (length . trustedCallersForRoute) (routesForRole role)))
            , signing_principal_code =
                fromIntegral (callerPrincipalCode (CallerService role))
            , signing_key_name =
                controlPlaneSigningKeyName
                  (controlPlaneSigningKeyRefFor (CallerService role))
            , trusted_callers =
                [ ControlPlaneTrustedCallerWire
                    { trusted_route_path = Text.pack (controlPlaneRoutePath route)
                    , trusted_caller_code = fromIntegral (callerPrincipalCode caller)
                    , trusted_signing_key_name =
                        controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor caller)
                    }
                | route <- routesForRole role
                , caller <- trustedCallersForRoute route
                ]
            }
      }
  isRight value = case value of
    Left _ -> False
    Right _ -> True
  shouldFailWith result expected = case result of
    Left actual -> actual `shouldBe` expected
    Right _ -> expectationFailure "expected schema-v7 control-plane config validation to fail"
  projectionImportMatrix =
    Map.fromList
      [ (LeaseProjection, ProjectionReleasedPredecessor digest)
      , (CheckpointProjection, ProjectionLegacy otherDigest)
      , (TargetIntentProjection, ProjectionStaged digest otherDigest)
      , (SmtpProjection, ProjectionMissing)
      ]
  projectionImportCommands =
    fmap (uncurry RecordProjectionImport) (Map.toAscList projectionImportMatrix)
      ++ [CompleteProjectionImports]
  migrationCommands =
    [VerifyShadow digest, FreezeLegacy digest]
      ++ fmap PrepareBinding [minBound .. maxBound]
      ++ [ActivateReplacement epoch]
  apply state command = fst (stepMigration state command)
  applyImport state command = fst (stepMigrationImport state command)

inMemoryRepository
  :: IORef (Maybe (StoredMigration Word))
  -> IORef Word
  -> Bool
  -> MigrationRepository IO Word
inMemoryRepository stateRef revisionRef forceConflict =
  MigrationRepository
    { readMigrationState = Right <$> readIORef stateRef
    , compareAndSwapMigrationState = \expected bytes ->
        if forceConflict
          then pure (Right False)
          else do
            observed <- readIORef stateRef
            let observedRevision = storedMigrationRevision <$> observed
            if observedRevision /= expected
              then pure (Right False)
              else do
                nextRevision <- atomicModifyIORef' revisionRef (\value -> (value + 1, value + 1))
                writeIORef stateRef (Just (StoredMigration nextRevision bytes))
                pure (Right True)
    }

isAccepted :: Either MigrationApplyError MigrationApplyResult -> Bool
isAccepted result = case result of
  Right applied -> case appliedMigrationDecision applied of
    MigrationAccepted _ -> True
    _ -> False
  Left _ -> False

isAlreadyApplied :: Either MigrationApplyError MigrationApplyResult -> Bool
isAlreadyApplied result = case result of
  Right applied -> appliedMigrationDecision applied == MigrationAlreadyApplied
  Left _ -> False

isRefused :: Either MigrationApplyError MigrationApplyResult -> Bool
isRefused result = case result of
  Right applied -> case appliedMigrationDecision applied of
    MigrationRefused _ -> True
    _ -> False
  Left _ -> False

isImportAccepted :: Either MigrationApplyError MigrationImportApplyResult -> Bool
isImportAccepted result = case result of
  Right applied -> appliedMigrationImportDecision applied == MigrationImportAccepted
  Left _ -> False

isImportAlreadyApplied :: Either MigrationApplyError MigrationImportApplyResult -> Bool
isImportAlreadyApplied result = case result of
  Right applied -> appliedMigrationImportDecision applied == MigrationImportAlreadyApplied
  Left _ -> False

isImportRefused :: Either MigrationApplyError MigrationImportApplyResult -> Bool
isImportRefused result = case result of
  Right applied -> case appliedMigrationImportDecision applied of
    MigrationImportRefused _ -> True
    _ -> False
  Left _ -> False

isMigrationAcceptedDecision :: MigrationDecision -> Bool
isMigrationAcceptedDecision decision = case decision of
  MigrationAccepted _ -> True
  _ -> False

replaceLastByte :: Word8 -> LazyByteString.ByteString -> LazyByteString.ByteString
replaceLastByte byte bytes
  | LazyByteString.null bytes = bytes
  | otherwise = LazyByteString.snoc (LazyByteString.init bytes) byte

interruptBeforeWriteRepository
  :: IORef (Maybe (StoredMigration Word))
  -> IORef Word
  -> IORef Bool
  -> MigrationRepository IO Word
interruptBeforeWriteRepository stateRef revisionRef failureRef =
  MigrationRepository
    { readMigrationState = Right <$> readIORef stateRef
    , compareAndSwapMigrationState = \expected bytes -> do
        shouldFail <- atomicModifyIORef' failureRef (False,)
        if shouldFail
          then pure (Left "interrupted-before-epoch")
          else
            compareAndSwapMigrationState
              (inMemoryRepository stateRef revisionRef False)
              expected
              bytes
    }

interruptAfterWriteRepository
  :: IORef (Maybe (StoredMigration Word))
  -> IORef Word
  -> IORef Bool
  -> MigrationRepository IO Word
interruptAfterWriteRepository stateRef revisionRef failureRef =
  MigrationRepository
    { readMigrationState = Right <$> readIORef stateRef
    , compareAndSwapMigrationState = \expected bytes -> do
        result <-
          compareAndSwapMigrationState
            (inMemoryRepository stateRef revisionRef False)
            expected
            bytes
        shouldFail <- readIORef failureRef
        case result of
          Right True
            | shouldFail -> do
                writeIORef failureRef False
                pure (Left "interrupted-after-epoch")
          _ -> pure result
    }

retainedMigrationCoordinate
  :: Checkpoint.ModelBObjectCoordinate 'Checkpoint.ClusterRetained
retainedMigrationCoordinate =
  mustRight
    ( Checkpoint.mkClusterRetainedCoordinate
        retainedAuthority
        "authority/migration-state"
    )

retainedAuthority :: Checkpoint.LongLivedCheckpointAuthority
retainedAuthority =
  mustRight
    ( Checkpoint.mkLongLivedCheckpointAuthority
        "home"
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )

requestState
  :: Checkpoint.ModelBCasRequest l MigrationState
  -> MigrationState
requestState request = case request of
  Checkpoint.ModelBInitialize _ state -> state
  Checkpoint.ModelBReplace _ _ state -> state
  Checkpoint.ModelBInitializeGuarded _ _ state -> state
  Checkpoint.ModelBReplaceGuarded _ _ _ state -> state

mustRight :: Either err value -> value
mustRight value = case value of
  Left _ -> error "expected a valid retained migration fixture"
  Right result -> result

testFailure :: String -> IO value
testFailure = ioError . userError
