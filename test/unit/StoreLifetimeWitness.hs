{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.51 witness for the 'StoreLifetime' phantom index on the Model-B
-- coordinate/request/adapter types.
--
-- Two properties are asserted here, and one is asserted by the fact that this
-- module (and the whole tree) compiles:
--
--   * BYTE ERASURE (the top-risk mitigation). The lifetime tag is a fully-erased
--     phantom: 'mkClusterRetainedCoordinate' and 'mkChartLifetimeCoordinate'
--     produce byte-identical authority and logical name for the same input, so
--     re-tagging a coordinate can never drift the sealed-envelope bytes a
--     downstream adapter would key or seal by.
--   * WELL-TYPED PATHS. A @'ClusterRetained'@ coordinate observes/CAS-es through
--     a @'ClusterRetained'@ adapter, and a @'ChartLifetime'@ coordinate through a
--     @'ChartLifetime'@ adapter — the same polymorphic in-memory fake serves both
--     once its @l@ is fixed.
--   * COMPILE WITNESS. The two ill-typed expressions documented at
--     'compileWitnessRejections' below do not typecheck (a @'ChartLifetime' /=
--     'ClusterRetained'@ mismatch); uncommenting either fails the build. That the
--     production cascade compiles is the positive half of the same proof.
module StoreLifetimeWitness
  ( storeLifetimeWitnessSuite
  )
where

import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObservation (..)
  , StoreLifetime (ChartLifetime, ClusterRetained)
  , mkChartLifetimeCoordinate
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectAuthority
  , modelBObjectLogicalName
  )
import TestSupport

storeLifetimeWitnessSuite :: SuiteBuilder ()
storeLifetimeWitnessSuite =
  describe "Sprint 4.51 durability-index phantom witness" $ do
    it "erases the lifetime tag: identical authority and logical name across lifetimes" $ do
      let name = "leases/123456789012/ca-central-1/aws-ses"
          retained = expectRight (mkClusterRetainedCoordinate authority name)
          chart = expectRight (mkChartLifetimeCoordinate authority name)
      modelBObjectLogicalName retained `shouldBe` name
      modelBObjectLogicalName chart `shouldBe` name
      modelBObjectLogicalName retained `shouldBe` modelBObjectLogicalName chart
      modelBObjectAuthority retained `shouldBe` authority
      modelBObjectAuthority chart `shouldBe` authority

    it "admits a well-typed ClusterRetained observe/CAS round trip" $ do
      store <- newIORef (ModelBMissing :: ModelBObservation BS.ByteString)
      let adapter = fakeAdapter store :: ModelBCasAdapter 'ClusterRetained IO BS.ByteString
          coordinate = expectRight (mkClusterRetainedCoordinate authority "leases/retained")
      observed <- modelBObserve adapter coordinate
      observed `shouldBe` ModelBMissing
      applied <- modelBCompareAndSwap adapter (ModelBInitialize coordinate "v1")
      case applied of
        ModelBCasApplied _ value -> value `shouldBe` "v1"
        other -> expectationFailure ("expected ModelBCasApplied, got " ++ show other)

    it "admits a well-typed ChartLifetime observe/CAS round trip" $ do
      store <- newIORef (ModelBMissing :: ModelBObservation BS.ByteString)
      let adapter = fakeAdapter store :: ModelBCasAdapter 'ChartLifetime IO BS.ByteString
          coordinate = expectRight (mkChartLifetimeCoordinate authority "pulumi-stack/per-run")
      observed <- modelBObserve adapter coordinate
      observed `shouldBe` ModelBMissing
      applied <- modelBCompareAndSwap adapter (ModelBInitialize coordinate "v1")
      case applied of
        ModelBCasApplied _ value -> value `shouldBe` "v1"
        other -> expectationFailure ("expected ModelBCasApplied, got " ++ show other)

-- The compile witness. Each expression below is rejected by GHC with a
-- 'ChartLifetime /= 'ClusterRetained StoreLifetime mismatch; uncommenting either
-- fails the build, proving retained state cannot be written through a
-- chart-lifetime transport (and vice-versa):
--
--   -- observe a retained coordinate through a chart-lifetime adapter:
--   modelBObserve
--     (fakeAdapter undefined :: ModelBCasAdapter 'ChartLifetime IO BS.ByteString)
--     (expectRight (mkClusterRetainedCoordinate authority "leases/x"))
--
--   -- write a chart-lifetime coordinate through a retained adapter:
--   modelBCompareAndSwap
--     (fakeAdapter undefined :: ModelBCasAdapter 'ClusterRetained IO BS.ByteString)
--     (ModelBInitialize (expectRight (mkChartLifetimeCoordinate authority "pulumi-stack/x")) "v1")

authority :: LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "https://gateway.example.test"
        "prodbox-state"
        "lifecycle"
        "transit/prodbox"
    )

-- | A minimal in-memory CAS adapter, polymorphic in the storage lifetime @l@, so
-- the same fake instantiates at both 'ClusterRetained' and 'ChartLifetime'.
fakeAdapter
  :: IORef (ModelBObservation BS.ByteString)
  -> ModelBCasAdapter l IO BS.ByteString
fakeAdapter store =
  ModelBCasAdapter
    { modelBObserve = \_ -> readIORef store
    , modelBCompareAndSwap = \request ->
        let value = requestValue request
            version = expectRight (mkModelBObjectVersion "witness-v1")
         in do
              writeIORef store (ModelBObserved version value)
              pure (ModelBCasApplied version value)
    }

requestValue :: ModelBCasRequest l BS.ByteString -> BS.ByteString
requestValue request = case request of
  ModelBInitialize _ value -> value
  ModelBReplace _ _ value -> value
  ModelBInitializeGuarded _ _ value -> value
  ModelBReplaceGuarded _ _ _ value -> value

expectRight :: (Show error) => Either error value -> value
expectRight (Right value) = value
expectRight (Left err) = error ("expectRight: unexpected Left " ++ show err)
