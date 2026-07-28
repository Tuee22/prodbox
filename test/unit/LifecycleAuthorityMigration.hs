{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityMigration (lifecycleAuthorityMigrationSuite) where

import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Prodbox.ControlPlane.Runtime
  ( ControlPlaneConfigError (..)
  , validateControlPlaneConfig
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
    it "round-trips the activated state through bounded canonical CBOR" $ do
      let final = foldl apply initialMigrationState migrationCommands
          encoded = encodeMigrationState final
      decodeMigrationState 4096 encoded `shouldBe` Right final
      decodeMigrationState 1 encoded `shouldBe` Left MigrationEnvelopeTooLarge
      decodeMigrationState 4096 (LazyByteString.pack [255])
        `shouldBe` Left MigrationEnvelopeInvalid
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
    it "refuses a mounted control-plane config for a different runtime role" $ do
      let roles =
            [ LifecycleAuthorityRuntime
            , ProviderWorkerRuntime
            , AuthorityBackupRuntime
            , TlsRetentionRuntime
            , TargetSecretAgentRuntime
            ]
      mapM_
        ( \role -> do
            validateControlPlaneConfig role 2 (Text.pack (runtimeRoleName role))
              `shouldBe` Right ()
            validateControlPlaneConfig role 2 "gateway-runtime"
              `shouldBe` Left ControlPlaneConfigRoleMismatch
            validateControlPlaneConfig role 1 (Text.pack (runtimeRoleName role))
              `shouldBe` Left ControlPlaneConfigVersionUnsupported
        )
        roles
 where
  digest = fromJust (mkMigrationDigest "fixture-v1")
  epoch = fromJust (mkMigrationEpoch 2)
  migrationCommands =
    [VerifyShadow digest, FreezeLegacy digest]
      ++ fmap PrepareBinding [minBound .. maxBound]
      ++ [ActivateReplacement epoch]
  apply state command = fst (stepMigration state command)

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
        "https://authority.example.test"
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
