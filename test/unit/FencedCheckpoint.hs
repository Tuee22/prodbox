{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module FencedCheckpoint
  ( fencedCheckpointSuite
  )
where

import Data.ByteString qualified as BS
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ChartLifetime, ClusterRetained)
  , mkChartLifetimeCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Lease
  ( FencedCommitPermit
  , LeaseAcquireDecision (..)
  , LeaseCommitDecision (..)
  , LeaseKey
  , authorityTimeFromMicros
  , beginLeaseAcquire
  , decideFencedCommit
  , decideLeaseAcquire
  , defaultSesLeasePolicy
  , leaseObjectCoordinate
  , leaseProjectionActiveGrant
  , mkLeaseKey
  , mkOwnerNonce
  )
import Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError (..)
  , PulumiStackRef (..)
  , withFencedDecryptedStackEnvironment
  )
import TestSupport

data FakeCheckpointStore = FakeCheckpointStore
  { fakeCheckpointObservation :: !(ModelBObservation BS.ByteString)
  , fakeCheckpointCasCount :: !Int
  , fakeCheckpointForceConflict :: !Bool
  }

fencedCheckpointSuite :: SuiteBuilder ()
fencedCheckpointSuite =
  describe "Sprint 4.47 fenced Pulumi checkpoint writeback" $ do
    it "initializes a missing checkpoint only after commit authorization" $ do
      stateRef <- newStore ModelBMissing False
      authorizationCount <- newIORef (0 :: Int)
      result <-
        withFencedDecryptedStackEnvironment
          (fakeAdapter stateRef)
          checkpointCoordinate
          leaseCoordinate
          Nothing
          stackRef
          []
          (modifyIORef' authorizationCount (+ 1) >> pure (Right commitPermit))
          ( \environment -> do
              lookup "PULUMI_BACKEND_URL" environment `shouldSatisfy` maybe False (const True)
              let checkpointPath =
                    pulumiScratchCheckpointPathFromEnvironment environment
              BS.writeFile checkpointPath validCheckpoint
              pure (Right ("reconciled" :: String))
          )
      result `shouldBe` Right "reconciled"
      readIORef authorizationCount `shouldReturn` 1
      finalState <- readIORef stateRef
      fakeCheckpointCasCount finalState `shouldBe` 1
      case fakeCheckpointObservation finalState of
        ModelBObserved _ bytes -> bytes `shouldBe` validCheckpoint
        other -> expectationFailure ("expected stored checkpoint, got " ++ show other)

    it "refuses writeback when the lease revalidation refuses" $ do
      stateRef <- newStore ModelBMissing False
      result <-
        runFenced stateRef (pure (Left "lease ownership lost"))
      result
        `shouldBe` Left
          (EncryptedBackendStoreFailed "fenced checkpoint commit refused: lease ownership lost")
      finalState <- readIORef stateRef
      fakeCheckpointCasCount finalState `shouldBe` 0
      fakeCheckpointObservation finalState `shouldBe` ModelBMissing

    it "surfaces a conditional-write conflict and never reports the action committed" $ do
      stateRef <- newStore ModelBMissing True
      result <- runFenced stateRef (pure (Right commitPermit))
      result
        `shouldBe` Left
          (EncryptedBackendStoreFailed "fenced checkpoint CAS conflicted with a newer authority version")
      (fakeCheckpointCasCount <$> readIORef stateRef) `shouldReturn` 1

runFenced
  :: IORef FakeCheckpointStore
  -> IO (Either String FencedCommitPermit)
  -> IO (Either EncryptedBackendError ())
runFenced stateRef authorize =
  withFencedDecryptedStackEnvironment
    (fakeAdapter stateRef)
    checkpointCoordinate
    leaseCoordinate
    Nothing
    stackRef
    []
    authorize
    ( \environment -> do
        BS.writeFile
          (pulumiScratchCheckpointPathFromEnvironment environment)
          validCheckpoint
        pure (Right ())
    )

-- The file backend URL is always @file://<scratch-root>@ and Pulumi stores the
-- checkpoint beneath @.pulumi/stacks/<project>/<stack>.json@.
pulumiScratchCheckpointPathFromEnvironment :: [(String, String)] -> FilePath
pulumiScratchCheckpointPathFromEnvironment environment =
  case lookup "PULUMI_BACKEND_URL" environment of
    Just ('f' : 'i' : 'l' : 'e' : ':' : '/' : '/' : root) ->
      root ++ "/.pulumi/stacks/prodbox-aws-ses/aws-ses.json"
    other -> error ("missing scratch PULUMI_BACKEND_URL: " ++ show other)

newStore
  :: ModelBObservation BS.ByteString
  -> Bool
  -> IO (IORef FakeCheckpointStore)
newStore observation forceConflict =
  newIORef
    FakeCheckpointStore
      { fakeCheckpointObservation = observation
      , fakeCheckpointCasCount = 0
      , fakeCheckpointForceConflict = forceConflict
      }

fakeAdapter :: IORef FakeCheckpointStore -> ModelBCasAdapter 'ChartLifetime IO BS.ByteString
fakeAdapter stateRef =
  ModelBCasAdapter
    { modelBObserve = const (fakeCheckpointObservation <$> readIORef stateRef)
    , modelBCompareAndSwap = \request -> do
        state <- readIORef stateRef
        let count = fakeCheckpointCasCount state + 1
        if fakeCheckpointForceConflict state
          then do
            writeIORef stateRef state {fakeCheckpointCasCount = count}
            pure (ModelBCasConflict (fakeCheckpointObservation state))
          else do
            let bytes = case request of
                  ModelBInitialize _ value -> value
                  ModelBReplace _ _ value -> value
                  ModelBInitializeGuarded _ _ value -> value
                  ModelBReplaceGuarded _ _ _ value -> value
                version = expectRight (mkModelBObjectVersion "etag-applied")
                observation = ModelBObserved version bytes
            writeIORef
              stateRef
              state
                { fakeCheckpointObservation = observation
                , fakeCheckpointCasCount = count
                }
            pure (ModelBCasApplied version bytes)
    }

checkpointCoordinate :: ModelBObjectCoordinate 'ChartLifetime
checkpointCoordinate =
  expectRight
    ( mkChartLifetimeCoordinate
        authority
        "pulumi-stack/aws-ses"
    )

leaseCoordinate :: ModelBObjectCoordinate 'ClusterRetained
leaseCoordinate = expectRight (leaseObjectCoordinate authority leaseKey)

leaseKey :: LeaseKey
leaseKey = expectRight (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

commitPermit :: FencedCommitPermit
commitPermit =
  case decideLeaseAcquire defaultSesLeasePolicy startedAt acquireRequest Nothing ModelBMissing of
    LeaseAcquireCompareAndSwap (ModelBInitialize _ projection) ->
      case leaseProjectionActiveGrant projection of
        Nothing -> error "expected active grant"
        Just grant ->
          case decideFencedCommit
            (authorityTimeFromMicros 2)
            grant
            (ModelBObserved leaseVersion projection) of
            LeaseCommitAuthorized permit -> permit
            other -> error ("expected commit permit, got " ++ show other)
    other -> error ("expected lease initialization, got " ++ show other)
 where
  startedAt = authorityTimeFromMicros 1
  owner = expectRight (mkOwnerNonce "fenced-checkpoint-test")
  acquireRequest =
    expectRight
      (beginLeaseAcquire defaultSesLeasePolicy authority leaseKey owner startedAt)
  leaseVersion = expectRight (mkModelBObjectVersion "lease-etag")

authority :: LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "prodbox-home"
        "http://127.0.0.1:30443"
        "prodbox-state"
        "lifecycle"
        "secret/lifecycle"
    )

stackRef :: PulumiStackRef
stackRef = PulumiStackRef "prodbox-aws-ses" "aws-ses"

validCheckpoint :: BS.ByteString
validCheckpoint = "{\"version\":3,\"checkpoint\":{}}"

expectRight :: (Show error) => Either error value -> value
expectRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " ++ show err)
