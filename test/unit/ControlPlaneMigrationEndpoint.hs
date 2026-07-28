{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneMigrationEndpoint (controlPlaneMigrationEndpointSuite) where

import Data.IORef
import Data.Maybe (fromJust)
import Prodbox.ControlPlane.MigrationEndpoint
  ( migrationEndpointHttpStatus
  , migrationEndpointSummary
  , serveMigrationApply
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationBinding
  , MigrationCommand (..)
  , decodeMigrationCommand
  , encodeMigrationCommand
  , mkMigrationDigest
  , mkMigrationEpoch
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (..)
  , StoredMigration (..)
  )
import TestSupport

controlPlaneMigrationEndpointSuite :: SuiteBuilder ()
controlPlaneMigrationEndpointSuite =
  describe "Sprint 4.50 Lifecycle Authority migration-apply endpoint" $ do
    it "round-trips every command through the bounded canonical request codec" $
      mapM_
        ( \command ->
            decodeMigrationCommand 4096 (encodeMigrationCommand command)
              `shouldBe` Right command
        )
        everyCommand
    it "refuses an oversized or invalid request body at the request codec" $ do
      decodeMigrationCommand 1 (encodeMigrationCommand (VerifyShadow digest))
        `shouldSatisfy` isLeft
      decodeMigrationCommand 4096 "not-a-valid-cbor-envelope"
        `shouldSatisfy` isLeft
    it "serves an accepted command as 200 and mutates once" $ do
      repository <- freshRepository
      result <- serveMigrationApply 4096 (fst repository) (encodeMigrationCommand (VerifyShadow digest))
      migrationEndpointHttpStatus result `shouldBe` 200
      migrationEndpointSummary result `shouldBe` "migration-accepted"
      readIORef (snd repository) `shouldReturn` 1
    it "reports a well-formed but refused command as 409 without mutating" $ do
      repository <- freshRepository
      result <- serveMigrationApply 4096 (fst repository) (encodeMigrationCommand RequestLegacyRollback)
      migrationEndpointHttpStatus result `shouldBe` 409
      migrationEndpointSummary result `shouldBe` "migration-refused:legacy-rollback-forbidden"
      readIORef (snd repository) `shouldReturn` 0
    it "rejects a malformed request body as 400 without touching the repository" $ do
      repository <- freshRepository
      result <- serveMigrationApply 4096 (fst repository) "garbage"
      migrationEndpointHttpStatus result `shouldBe` 400
      migrationEndpointSummary result `shouldBe` "migration-bad-request:invalid"
      readIORef (snd repository) `shouldReturn` 0
    it "rejects an oversized request body as 400" $ do
      repository <- freshRepository
      result <- serveMigrationApply 1 (fst repository) (encodeMigrationCommand (VerifyShadow digest))
      migrationEndpointHttpStatus result `shouldBe` 400
      migrationEndpointSummary result `shouldBe` "migration-bad-request:too-large"
    it "surfaces an unobservable retained read as 503" $ do
      result <-
        serveMigrationApply 4096 readFailingRepository (encodeMigrationCommand (VerifyShadow digest))
      migrationEndpointHttpStatus result `shouldBe` 503
      migrationEndpointSummary result `shouldBe` "migration-read-failed"
    it "surfaces a lost compare-and-swap race as 409" $ do
      stateRef <- newIORef Nothing
      revisionRef <- newIORef (0 :: Word)
      result <-
        serveMigrationApply
          4096
          (inMemoryRepository stateRef revisionRef True)
          (encodeMigrationCommand (VerifyShadow digest))
      migrationEndpointHttpStatus result `shouldBe` 409
      migrationEndpointSummary result `shouldBe` "migration-concurrent-write"
    it "drives the complete activation sequence to an accepted terminal write" $ do
      repository <- freshRepository
      results <-
        mapM
          (serveMigrationApply 4096 (fst repository) . encodeMigrationCommand)
          activationSequence
      fmap migrationEndpointHttpStatus results `shouldSatisfy` all (== 200)
      migrationEndpointSummary (last results) `shouldBe` "migration-accepted"
 where
  digest = fromJust (mkMigrationDigest "endpoint-v1")
  epoch = fromJust (mkMigrationEpoch 2)
  bindings = [minBound .. maxBound] :: [MigrationBinding]
  activationSequence =
    [VerifyShadow digest, FreezeLegacy digest]
      ++ fmap PrepareBinding bindings
      ++ [ActivateReplacement epoch]
  everyCommand =
    [VerifyShadow digest, FreezeLegacy digest, ActivateReplacement epoch, RequestLegacyRollback]
      ++ fmap PrepareBinding bindings

freshRepository :: IO (MigrationRepository IO Word, IORef Word)
freshRepository = do
  stateRef <- newIORef Nothing
  revisionRef <- newIORef (0 :: Word)
  pure (inMemoryRepository stateRef revisionRef False, revisionRef)

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

readFailingRepository :: MigrationRepository IO Word
readFailingRepository =
  MigrationRepository
    { readMigrationState = pure (Left "migration state is unobservable")
    , compareAndSwapMigrationState = \_ _ -> pure (Left "unreachable")
    }

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
