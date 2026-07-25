{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.51 Increment B (Stage B): the shared Model-B ↔ authority-object
-- translation ('modelBCasAdapterOverTransport') that BOTH the gateway transport
-- ('gatewayModelBCasAdapter') and the host-direct transport
-- ('hostDirectModelBCasAdapter') delegate to. Driving it over the same in-memory
-- conditional-put fake used for the Stage-A core proves the translation once for
-- both transports: coordinate-authority guarding, encode/decode, and the flat
-- observation/response → typed 'ModelBObservation' / 'ModelBCasResult' mapping.
-- Physical envelope byte-identity is structural (Stage A) and proven live by the
-- Standard-O AWS-substrate run; here we pin the transport-agnostic ModelB logic.
module HostDirectModelBAdapter
  ( hostDirectModelBAdapterSuite
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Prodbox.Lifecycle.AuthorityObjectCore
  ( AuthorityCore (..)
  , compareAndSwapAuthorityObjectCore
  , readAuthorityObjectCore
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBLeaseGuard (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.HostDirectAuthorityStore (hostDirectModelBCasAdapter)
import Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  )
import Prodbox.Lifecycle.StoreLifetime (StoreLifetime (ClusterRetained))
import Prodbox.Minio.EncryptedObject
  ( LogicalConditionalPutResult (..)
  , LogicalObject
  , VersionedLogicalObject (VersionedLogicalObject)
  )
import Prodbox.Minio.ObjectStore (ObjectVersion (ObjectVersion))
import Prodbox.Pulumi.HostDirectObjectStore (HostDirectPulumiHandle)
import TestSupport

type FakeStore = IORef (Map LogicalObject (ByteString, ObjectVersion))

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 7 18) (secondsToDiffTime 0)

-- | The exact in-memory conditional-put fake used for the Stage-A core: if-absent
-- applies only when missing, if-version only on a matching version, a put bumps
-- the version, and reads always return the current store version.
fakeCore :: FakeStore -> AuthorityCore IO
fakeCore ref =
  AuthorityCore
    { authGetVersioned = \obj -> do
        objects <- readIORef ref
        pure (Right (fmap toVersioned (Map.lookup obj objects)))
    , authPutIfAbsent = \obj payload -> do
        objects <- readIORef ref
        case Map.lookup obj objects of
          Just _ -> pure (Right LogicalConditionalPutConflict)
          Nothing -> do
            writeIORef ref (Map.insert obj (payload, ObjectVersion "v1") objects)
            pure (Right LogicalConditionalPutApplied)
    , authPutIfVersion = \obj (ObjectVersion expected) payload -> do
        objects <- readIORef ref
        case Map.lookup obj objects of
          Just (_, ObjectVersion current)
            | current == expected -> do
                writeIORef ref (Map.insert obj (payload, ObjectVersion (Text.snoc current '*')) objects)
                pure (Right LogicalConditionalPutApplied)
          _ -> pure (Right LogicalConditionalPutConflict)
    , authNow = pure fixedNow
    }
 where
  toVersioned (bytes, storeVersion) = VersionedLogicalObject bytes storeVersion

-- | A 'ModelBTransport' over the fake core — exactly how the real host-direct
-- transport wraps the real 'AuthorityObjectCore'.
fakeTransport :: FakeStore -> ModelBTransport
fakeTransport ref =
  ModelBTransport
    { transportObserveObject = \name ->
        first Text.pack <$> readAuthorityObjectCore (fakeCore ref) name
    , transportCasObject = \request ->
        first Text.pack <$> compareAndSwapAuthorityObjectCore (fakeCore ref) request
    }

authority :: LongLivedCheckpointAuthority
authority =
  either (error . show) id $
    mkLongLivedCheckpointAuthority "cluster" "http://authority:8080" "bucket" "namespace" "keyspace"

otherAuthority :: LongLivedCheckpointAuthority
otherAuthority =
  either (error . show) id $
    mkLongLivedCheckpointAuthority "other-cluster" "http://other:8080" "bucket" "namespace" "keyspace"

coordinate :: Text -> ModelBObjectCoordinate 'ClusterRetained
coordinate name = either (error . show) id (mkClusterRetainedCoordinate authority name)

otherCoordinate :: Text -> ModelBObjectCoordinate 'ClusterRetained
otherCoordinate name = either (error . show) id (mkClusterRetainedCoordinate otherAuthority name)

version :: Text -> ModelBObjectVersion
version value = either (error . show) id (mkModelBObjectVersion value)

byteCodec :: ModelBCodec ByteString
byteCodec = ModelBCodec {encodeModelBValue = Right, decodeModelBValue = Right}

encodeRefusedCodec :: ModelBCodec ByteString
encodeRefusedCodec =
  ModelBCodec {encodeModelBValue = \_ -> Left "encode refused", decodeModelBValue = Right}

adapter :: FakeStore -> ModelBCodec ByteString -> ModelBCasAdapter 'ClusterRetained IO ByteString
adapter ref codec = modelBCasAdapterOverTransport authority (fakeTransport ref) codec

casUnobservableContains :: String -> ModelBCasResult value -> Bool
casUnobservableContains needle (ModelBCasUnobservable message) = needle `isInfixOf` Text.unpack message
casUnobservableContains _ _ = False

unobservableContains :: String -> ModelBObservation value -> Bool
unobservableContains needle (ModelBUnobservable message) = needle `isInfixOf` Text.unpack message
unobservableContains _ _ = False

-- | Compile witness: the host-direct adapter is fixed to @'ClusterRetained@; a
-- @'ChartLifetime@ retained-authority write cannot be expressed through it.
hostDirectAdapterIsClusterRetained
  :: HostDirectPulumiHandle
  -> LongLivedCheckpointAuthority
  -> ModelBCodec ByteString
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
hostDirectAdapterIsClusterRetained = hostDirectModelBCasAdapter

hostDirectModelBAdapterSuite :: SuiteBuilder ()
hostDirectModelBAdapterSuite =
  describe "Sprint 4.51-B Model-B CAS over the shared transport" $ do
    describe "observe" $ do
      it "observes a missing object as ModelBMissing" $ do
        ref <- newIORef Map.empty
        result <- modelBObserve (adapter ref byteCodec) (coordinate "leases/aws-ses")
        result `shouldBe` ModelBMissing
      it "observes an applied object back at its store version" $ do
        ref <- newIORef Map.empty
        _ <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result <- modelBObserve (adapter ref byteCodec) (coordinate "leases/aws-ses")
        result `shouldBe` ModelBObserved (version "v1") "payload"
      it "refuses a coordinate that belongs to another authority" $ do
        ref <- newIORef Map.empty
        result <- modelBObserve (adapter ref byteCodec) (otherCoordinate "leases/aws-ses")
        result `shouldSatisfy` unobservableContains "does not belong"

    describe "compare-and-swap" $ do
      it "initialize on a missing object applies" $ do
        ref <- newIORef Map.empty
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result `shouldBe` ModelBCasApplied (version "v1") "payload"
      it "initialize on a present object conflicts with the current observation" $ do
        ref <- newIORef Map.empty
        _ <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload2")
        result `shouldBe` ModelBCasConflict (ModelBObserved (version "v1") "payload")
      it "replace on a matching version applies and bumps" $ do
        ref <- newIORef Map.empty
        _ <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBReplace (coordinate "leases/aws-ses") (version "v1") "payload2")
        result `shouldBe` ModelBCasApplied (version "v1*") "payload2"
      it "replace on a stale version conflicts" $ do
        ref <- newIORef Map.empty
        _ <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBReplace (coordinate "leases/aws-ses") (version "stale") "payload2")
        result `shouldBe` ModelBCasConflict (ModelBObserved (version "v1") "payload")
      it "refuses a target coordinate that belongs to another authority" $ do
        ref <- newIORef Map.empty
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitialize (otherCoordinate "leases/aws-ses") "payload")
        result `shouldSatisfy` casUnobservableContains "does not belong"
      it "refuses corrupt payload encoding as ModelBCasRefusedCorrupt" $ do
        ref <- newIORef Map.empty
        result <-
          modelBCompareAndSwap
            (adapter ref encodeRefusedCodec)
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result `shouldBe` ModelBCasRefusedCorrupt "encode refused"

    describe "lease-guarded CAS (fail-closed)" $ do
      it "refuses a guarded write when the guarded lease object is missing" $ do
        ref <- newIORef Map.empty
        let guard =
              ModelBLeaseGuard
                { modelBLeaseGuardCoordinate = coordinate "leases/aws-ses"
                , modelBLeaseGuardExpectedVersion = version "v1"
                , modelBLeaseGuardOwnerNonceText = "owner"
                , modelBLeaseGuardFencingTokenValue = 1
                }
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitializeGuarded (coordinate "smtp-commit/aws-ses") guard "payload")
        result `shouldSatisfy` casUnobservableContains "lease projection is missing"

    describe "transport type" $
      it "hostDirectModelBCasAdapter is a 'ClusterRetained adapter (type witness)" $
        hostDirectAdapterIsClusterRetained `seq`
          (True `shouldBe` True)
