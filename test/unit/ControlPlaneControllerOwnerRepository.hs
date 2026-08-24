{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneControllerOwnerRepository
  ( controlPlaneControllerOwnerRepositorySuite
  )
where

import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict qualified as Map
import Prodbox.ControlPlane.ControllerOwnerRepository
import Prodbox.Lib.AwsControlPlaneIsolation
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import TestSupport

controlPlaneControllerOwnerRepositorySuite :: SuiteBuilder ()
controlPlaneControllerOwnerRepositorySuite =
  describe "Sprint 7.36 retained controller-owner repository" $ do
    it "round-trips every canonical controller-owner phase" $ do
      let states =
            [ ControllerOwnerRegisteredInert fixtureDescriptor
            , ControllerOwnerUidRegistered fixtureDescriptor "service-uid"
            , ControllerOwnerEnabled fixtureDescriptor "service-uid"
            , ControllerChildArnsRegistered
                fixtureDescriptor
                "service-uid"
                ["arn:child:1", "arn:child:2"]
            ]
          codec = controllerOwnerModelBCodec
      mapM_
        (assertCodecRoundTrip codec)
        states
      decodeModelBValue codec ByteString.empty `shouldSatisfy` isLeft

    it "persists inert, UID, enable, and every exact child before answering" $ do
      durable <- newDurableControllerOwner False
      runTransition durable (RegisterControllerOwnerInert fixtureDescriptor)
        `shouldReturn` Right (ControllerOwnerRegisteredInert fixtureDescriptor)
      runTransition durable (RegisterControllerOwnerUid fixtureDescriptor "service-uid")
        `shouldReturn` Right (ControllerOwnerUidRegistered fixtureDescriptor "service-uid")
      runTransition durable (EnableRegisteredControllerOwner fixtureDescriptor)
        `shouldReturn` Right (ControllerOwnerEnabled fixtureDescriptor "service-uid")
      runTransition
        durable
        ( RegisterControllerOwnerChildArns
            fixtureDescriptor
            ["arn:child:2", "arn:child:1"]
        )
        `shouldReturn` Right
          ( ControllerChildArnsRegistered
              fixtureDescriptor
              "service-uid"
              ["arn:child:1", "arn:child:2"]
          )
      readIORef (durableWrites durable) `shouldReturn` 4
      readIORef (durableReads durable) `shouldReturn` 8

    it "settles an applied-but-response-lost CAS only by independent read-back" $ do
      durable <- newDurableControllerOwner True
      runTransition durable (RegisterControllerOwnerInert fixtureDescriptor)
        `shouldReturn` Right (ControllerOwnerRegisteredInert fixtureDescriptor)
      readIORef (durableWrites durable) `shouldReturn` 1
      readIORef (durableReads durable) `shouldReturn` 2

    it "refuses a UID conflict and a descriptor collision without a write" $ do
      durable <- newDurableControllerOwner False
      _ <- runTransition durable (RegisterControllerOwnerInert fixtureDescriptor)
      _ <- runTransition durable (RegisterControllerOwnerUid fixtureDescriptor "service-uid")
      runTransition durable (RegisterControllerOwnerUid fixtureDescriptor "different-uid")
        `shouldReturn` Left (ControllerOwnerTransitionRefused ControllerOwnerUidConflict)
      let conflicting = fixtureDescriptor {controllerOwnerManifestDigest = "sha256:different"}
      runTransition durable (RegisterControllerOwnerInert conflicting)
        `shouldReturn` Left
          (ControllerOwnerDescriptorConflict conflicting fixtureDescriptor)
      readIORef (durableWrites durable) `shouldReturn` 2

    it "rejects non-normalized child observations before CAS" $ do
      durable <- newDurableControllerOwner False
      _ <- runTransition durable (RegisterControllerOwnerInert fixtureDescriptor)
      _ <- runTransition durable (RegisterControllerOwnerUid fixtureDescriptor "service-uid")
      _ <- runTransition durable (EnableRegisteredControllerOwner fixtureDescriptor)
      runTransition
        durable
        ( RegisterControllerOwnerChildArns
            fixtureDescriptor
            ["arn:child:1", "arn:child:1"]
        )
        `shouldReturn` Left
          ( ControllerOwnerTransitionRefused
              (ControllerChildArnDuplicated "arn:child:1")
          )
      readIORef (durableWrites durable) `shouldReturn` 3

assertCodecRoundTrip
  :: ModelBCodec ControllerOwnerState
  -> ControllerOwnerState
  -> Expectation
assertCodecRoundTrip codec state = case encodeModelBValue codec state of
  Left err -> expectationFailure err
  Right encoded -> decodeModelBValue codec encoded `shouldBe` Right state

data DurableControllerOwner = DurableControllerOwner
  { durableAdapter
      :: ModelBCasAdapter 'ClusterRetained IO ControllerOwnerState
  , durableWrites :: IORef Int
  , durableReads :: IORef Int
  }

newDurableControllerOwner :: Bool -> IO DurableControllerOwner
newDurableControllerOwner loseFirstResponse = do
  valuesRef <- newIORef Map.empty
  writesRef <- newIORef 0
  readsRef <- newIORef 0
  loseRef <- newIORef loseFirstResponse
  let observe coordinate = do
        atomicModifyIORef' readsRef (\count -> (count + 1, ()))
        values <- readIORef valuesRef
        pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
          Nothing -> ModelBMissing
          Just (version, state) -> ModelBObserved version state
      compareAndSwap request = case request of
        ModelBInitialize coordinate state -> do
          let key = modelBObjectLogicalName coordinate
          values <- readIORef valuesRef
          case Map.lookup key values of
            Just (version, current) -> pure (ModelBCasConflict (ModelBObserved version current))
            Nothing -> storeApplied key state
        ModelBReplace coordinate expectedVersion state -> do
          let key = modelBObjectLogicalName coordinate
          values <- readIORef valuesRef
          case Map.lookup key values of
            Just (version, _) | version == expectedVersion -> storeApplied key state
            Just (version, current) -> pure (ModelBCasConflict (ModelBObserved version current))
            Nothing -> pure (ModelBCasConflict ModelBMissing)
        ModelBInitializeGuarded {} -> pure (ModelBCasRefusedCorrupt "guarded initialize")
        ModelBReplaceGuarded {} -> pure (ModelBCasRefusedCorrupt "guarded replace")
      storeApplied key state = do
        let version = fixtureVersionFor state
        atomicModifyIORef'
          valuesRef
          (\values -> (Map.insert key (version, state) values, ()))
        atomicModifyIORef' writesRef (\count -> (count + 1, ()))
        lose <-
          atomicModifyIORef'
            loseRef
            extractAndReset
        pure
          ( if lose
              then ModelBCasUnobservable "response lost"
              else ModelBCasApplied version state
          )
      extractAndReset shouldLose = (False, shouldLose)
  pure
    DurableControllerOwner
      { durableAdapter =
          ModelBCasAdapter
            { modelBObserve = observe
            , modelBCompareAndSwap = compareAndSwap
            }
      , durableWrites = writesRef
      , durableReads = readsRef
      }

runTransition
  :: DurableControllerOwner
  -> ControllerOwnerTransition
  -> IO (Either ControllerOwnerRepositoryError ControllerOwnerState)
runTransition durable =
  transitionControllerOwner fixtureAuthority (durableAdapter durable)

fixtureDescriptor :: ControllerOwnerDescriptor
fixtureDescriptor =
  ControllerOwnerDescriptor
    { controllerOwnerAccount = "123456789012"
    , controllerOwnerRegion = fixtureAwsRegion FixtureUsEast1
    , controllerOwnerCluster = "aws-eks-test-cluster"
    , controllerOwnerResourceName = "prodbox-public-edge"
    , controllerOwnerManifestDigest = "sha256:manifest"
    , controllerOwnerTags =
        [ ("prodbox.io/cluster", "aws-eks-test-cluster")
        , ("prodbox.io/managed-by", "prodbox")
        ]
    }

fixtureAuthority :: LongLivedCheckpointAuthority
fixtureAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-linux-rke2"
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

fixtureVersionFor :: ControllerOwnerState -> ModelBObjectVersion
fixtureVersionFor state =
  mustRight
    (mkModelBObjectVersion ("controller-owner-version-" <> stage state))
 where
  stage value = case value of
    ControllerOwnerRegisteredInert {} -> "0"
    ControllerOwnerUidRegistered {} -> "1"
    ControllerOwnerEnabled {} -> "2"
    ControllerChildArnsRegistered {} -> "3"

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

mustRight :: (Show left) => Either left right -> right
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
