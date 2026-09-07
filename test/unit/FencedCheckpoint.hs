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
import Data.List (isInfixOf)
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
  ( CheckpointCommitDecision (..)
  , EncryptedBackendError (..)
  , PulumiStackRef (..)
  , decideCheckpointCommit
  , withFencedDecryptedStackEnvironment
  )
import TestSupport

data FakeCheckpointStore = FakeCheckpointStore
  { fakeCheckpointObservation :: !(ModelBObservation BS.ByteString)
  , fakeCheckpointCasCount :: !Int
  , fakeCheckpointForceConflict :: !Bool
  }

fencedCheckpointSuite :: SuiteBuilder ()
fencedCheckpointSuite = do
  checkpointRetirementSuite
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
leaseKey = expectRight (mkLeaseKey "123456789012" (fixtureAwsRegion FixtureCaCentral1) "aws-ses")

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

-- | The 2026-09-07 post-mortem: a cascade retired the @aws-eks@ checkpoint after
-- a destroy that never removed anything, so every later run observed
-- @CheckpointAbsent@, mapped it to @ResidueAbsent@, skipped the destroy and
-- reported the phase clean while an EKS cluster and VPC stayed live. These pin
-- the rule that stops it: an empty scratch backend is a retirement only when the
-- action that emptied it succeeded.
checkpointRetirementSuite :: SuiteBuilder ()
checkpointRetirementSuite =
  describe "checkpoint retirement requires a successful action" $ do
    it "retires when retirement is permitted and the action succeeded" $
      decideCheckpointCommit True Nothing Nothing
        `shouldBe` CommitCheckpointRetirement

    it "REFUSES to retire when the action failed and left no checkpoint" $
      case decideCheckpointCommit True (Just "pulumi destroy exited 255") Nothing of
        RefuseRetirementAfterFailedAction detail -> do
          detail `shouldSatisfy` isInfixOf "pulumi destroy exited 255"
          detail `shouldSatisfy` isInfixOf "PRESERVED"
        other ->
          expectationFailure
            ("a failed action must never retire the checkpoint, got " ++ show other)

    it "writes collected bytes back even when the action failed, so partial progress survives" $
      decideCheckpointCommit True (Just "destroy failed part-way") (Just validCheckpoint)
        `shouldBe` CommitCheckpointBytes validCheckpoint

    it "never retires when the transaction forbids retirement" $ do
      decideCheckpointCommit False Nothing Nothing
        `shouldSatisfy` isUnpermitted
      decideCheckpointCommit False (Just "boom") Nothing
        `shouldSatisfy` isUnpermitted

    it "still commits bytes when retirement is forbidden" $
      decideCheckpointCommit False Nothing (Just validCheckpoint)
        `shouldBe` CommitCheckpointBytes validCheckpoint
 where
  isUnpermitted decision = case decision of
    RefuseRetirementUnpermitted _ -> True
    _ -> False
