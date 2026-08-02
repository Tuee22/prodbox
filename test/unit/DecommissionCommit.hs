{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionCommit (decommissionCommitSuite) where

import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.IORef
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Decommission.Commit
import Prodbox.Lifecycle.Decommission.Frame (contentDigest)
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.Verifier
import TestSupport

decommissionCommitSuite :: SuiteBuilder ()
decommissionCommitSuite =
  describe "Sprint 4.50 decommission manifest commit" $ do
    it "round-trips only an authenticated complete manifest through the retained codec" $ do
      let codec = decommissionManifestCodec 8192 signerDigest
          encoded = mustRight (encodeModelBValue codec verifiedPlanA)
      decodeModelBValue codec encoded `shouldBe` Right verifiedPlanA
      decodeModelBValue (decommissionManifestCodec 1 signerDigest) encoded
        `shouldSatisfy` isLeft
      decodeModelBValue (decommissionManifestCodec 8192 otherSignerDigest) encoded
        `shouldSatisfy` isLeft
      encodeModelBValue codec otherSignerVerifiedPlanA `shouldSatisfy` isLeft
    it "commits a fresh plan and stores it" $ do
      (repository, ref) <- freshRepository
      outcome <- commitDecommissionManifest repository verifiedPlanA
      outcome `shouldBe` Right CommittedNew
      stored <- readIORef ref
      fmap snd stored `shouldBe` Just verifiedPlanA
    it "is idempotent when the same plan is re-committed" $ do
      (repository, ref) <- freshRepository
      _ <- commitDecommissionManifest repository verifiedPlanA
      versionBefore <- fmap (fmap fst) (readIORef ref)
      outcome <- commitDecommissionManifest repository verifiedPlanA
      outcome `shouldBe` Right CommittedAlready
      versionAfter <- fmap (fmap fst) (readIORef ref)
      versionAfter `shouldBe` versionBefore
    it "refuses to overwrite a different committed plan" $ do
      (repository, _) <- freshRepository
      _ <- commitDecommissionManifest repository verifiedPlanA
      outcome <- commitDecommissionManifest repository verifiedPlanB
      outcome
        `shouldBe` Right
          ( RefusedDifferentPlan
              (verifiedManifestDigest verifiedPlanA)
              (verifiedManifestDigest verifiedPlanB)
          )
    it "surfaces an unobservable committed store as a read failure" $ do
      let repository = modelBDecommissionCommitRepository corruptAdapter coordinate
      outcome <- commitDecommissionManifest repository verifiedPlanA
      case outcome of
        Left (CommitReadFailed _) -> pure ()
        other -> expectationFailure ("expected a read failure, got " <> show other)
    it "reports a lost initialize race as a concurrent write" $ do
      ref <- newIORef Nothing
      let repository = modelBDecommissionCommitRepository (inMemoryAdapter ref True) coordinate
      outcome <- commitDecommissionManifest repository verifiedPlanA
      outcome `shouldBe` Left CommitConcurrentWrite
 where
  planA =
    mustRight (mkDecommissionManifest "home" [SesProviderStack, TlsRetainedObjects, SharedObjectBucket])
  planB = mustRight (mkDecommissionManifest "aws" [SesProviderStack, SharedObjectBucket])
  dependencyBytes = "dependency closure v1"
  metadata =
    mustRight
      ( mkVerifierMetadata
          (contentDigest dependencyBytes)
          1
          (contentDigest "manifest-schema-v1")
          1
          (contentDigest "interpreter-registry-v1")
      )
  artifact = mustRight (mkVerifierArtifact "runner-build-v1" dependencyBytes metadata)
  artifactPath = mustRight (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")
  signingKey = mustRight (mkManifestSigningKey (ByteString.pack [0 .. 31]))
  signerDigest = manifestPublicKeyDigest (manifestSigningPublicKey signingKey)
  otherSigningKey = mustRight (mkManifestSigningKey (ByteString.pack [32 .. 63]))
  otherSignerDigest =
    manifestPublicKeyDigest
      (manifestSigningPublicKey otherSigningKey)
  binding = verifierBindingOf artifactPath artifact
  signedPlanA = signDecommissionManifest signingKey planA binding
  signedPlanB = signDecommissionManifest signingKey planB binding
  verifiedPlanA = mustRight (verifySignedDecommissionManifest signerDigest signedPlanA)
  verifiedPlanB = mustRight (verifySignedDecommissionManifest signerDigest signedPlanB)
  otherSignerVerifiedPlanA =
    mustRight
      ( verifySignedDecommissionManifest
          otherSignerDigest
          (signDecommissionManifest otherSigningKey planA binding)
      )
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
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )

inMemoryAdapter
  :: IORef (Maybe (ModelBObjectVersion, VerifiedDecommissionManifest))
  -> Bool
  -> ModelBCasAdapter 'ClusterRetained IO VerifiedDecommissionManifest
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
  :: IORef (Maybe (ModelBObjectVersion, VerifiedDecommissionManifest))
  -> Bool
  -> ModelBCasRequest 'ClusterRetained VerifiedDecommissionManifest
  -> IO (ModelBCasResult VerifiedDecommissionManifest)
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

corruptAdapter :: ModelBCasAdapter 'ClusterRetained IO VerifiedDecommissionManifest
corruptAdapter =
  ModelBCasAdapter
    { modelBObserve = \_ -> pure (ModelBCorrupt "committed manifest bytes are corrupt")
    , modelBCompareAndSwap = \_ -> pure (ModelBCasUnobservable "unreachable")
    }

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
