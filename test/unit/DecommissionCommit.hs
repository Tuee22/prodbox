{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionCommit (decommissionCommitSuite) where

import Data.IORef
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Decommission.Commit
import Prodbox.Lifecycle.Decommission.Manifest
import TestSupport

decommissionCommitSuite :: SuiteBuilder ()
decommissionCommitSuite =
  describe "Sprint 4.50 decommission manifest commit" $ do
    it "round-trips a manifest through the bounded canonical codec" $ do
      decodeDecommissionManifest 8192 (encodeDecommissionManifest planA)
        `shouldBe` Right planA
      decodeDecommissionManifest 1 (encodeDecommissionManifest planA)
        `shouldBe` Left ManifestEnvelopeTooLarge
      decodeDecommissionManifest 8192 "not-a-manifest"
        `shouldBe` Left ManifestEnvelopeInvalid
    it "commits a fresh plan and stores it" $ do
      (repository, ref) <- freshRepository
      outcome <- commitDecommissionManifest repository planA
      outcome `shouldBe` Right CommittedNew
      stored <- readIORef ref
      fmap snd stored `shouldBe` Just planA
    it "is idempotent when the same plan is re-committed" $ do
      (repository, ref) <- freshRepository
      _ <- commitDecommissionManifest repository planA
      versionBefore <- fmap (fmap fst) (readIORef ref)
      outcome <- commitDecommissionManifest repository planA
      outcome `shouldBe` Right CommittedAlready
      versionAfter <- fmap (fmap fst) (readIORef ref)
      versionAfter `shouldBe` versionBefore
    it "refuses to overwrite a different committed plan" $ do
      (repository, _) <- freshRepository
      _ <- commitDecommissionManifest repository planA
      outcome <- commitDecommissionManifest repository planB
      outcome
        `shouldBe` Right
          (RefusedDifferentPlan (decommissionManifestDigest planA) (decommissionManifestDigest planB))
    it "surfaces an unobservable committed store as a read failure" $ do
      let repository = modelBDecommissionCommitRepository corruptAdapter coordinate
      outcome <- commitDecommissionManifest repository planA
      case outcome of
        Left (CommitReadFailed _) -> pure ()
        other -> expectationFailure ("expected a read failure, got " <> show other)
    it "reports a lost initialize race as a concurrent write" $ do
      ref <- newIORef Nothing
      let repository = modelBDecommissionCommitRepository (inMemoryAdapter ref True) coordinate
      outcome <- commitDecommissionManifest repository planA
      outcome `shouldBe` Left CommitConcurrentWrite
 where
  planA =
    mustRight (mkDecommissionManifest "home" [SesProviderStack, TlsRetainedObjects, SharedObjectBucket])
  planB = mustRight (mkDecommissionManifest "aws" [SesProviderStack, SharedObjectBucket])
  freshRepository = do
    ref <- newIORef Nothing
    pure (modelBDecommissionCommitRepository (inMemoryAdapter ref False) coordinate, ref)

coordinate :: ModelBObjectCoordinate 'ClusterRetained
coordinate =
  mustRight (mkClusterRetainedCoordinate retainedAuthority "authority/decommission-manifest")

retainedAuthority :: LongLivedCheckpointAuthority
retainedAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home"
        "https://authority.example.test"
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )

inMemoryAdapter
  :: IORef (Maybe (ModelBObjectVersion, DecommissionManifest))
  -> Bool
  -> ModelBCasAdapter 'ClusterRetained IO DecommissionManifest
inMemoryAdapter ref forceConflict =
  ModelBCasAdapter
    { modelBObserve = \_ -> do
        stored <- readIORef ref
        pure $ case stored of
          Nothing -> ModelBMissing
          Just (version, manifest) -> ModelBObserved version manifest
    , modelBCompareAndSwap = initializeOnly ref forceConflict
    }

initializeOnly
  :: IORef (Maybe (ModelBObjectVersion, DecommissionManifest))
  -> Bool
  -> ModelBCasRequest 'ClusterRetained DecommissionManifest
  -> IO (ModelBCasResult DecommissionManifest)
initializeOnly ref forceConflict request = case request of
  ModelBInitialize _ manifest
    | forceConflict -> pure (ModelBCasConflict ModelBMissing)
    | otherwise -> do
        existing <- readIORef ref
        case existing of
          Just (version, committed) -> pure (ModelBCasConflict (ModelBObserved version committed))
          Nothing -> do
            let version = mustRight (mkModelBObjectVersion "commit-v1")
            writeIORef ref (Just (version, manifest))
            pure (ModelBCasApplied version manifest)
  _ -> pure (ModelBCasUnobservable "unexpected decommission commit request")

corruptAdapter :: ModelBCasAdapter 'ClusterRetained IO DecommissionManifest
corruptAdapter =
  ModelBCasAdapter
    { modelBObserve = \_ -> pure (ModelBCorrupt "committed manifest bytes are corrupt")
    , modelBCompareAndSwap = \_ -> pure (ModelBCasUnobservable "unreachable")
    }

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
