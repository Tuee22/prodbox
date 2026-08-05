{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.53: the typed three-valued endpoint-readiness classifier and the
-- ONE shared Model-B <-> authority-object translation
-- ('modelBCasAdapterOverTransport') that every retained-authority transport
-- delegates to.
--
-- This module replaces @test/unit/HostDirectModelBAdapter.hs@, which Sprint
-- 4.50 deleted along with the host-direct store it was named for. The store is
-- gone; the seam it exercised is not, so the coverage moves to the surviving
-- module rather than disappearing with the transport that happened to host it.
--
-- The classifier cases are the point. Sprint 4.53 exists to make the
-- \"bring-up dual\" unrepresentable: a not-yet-ready endpoint must land in a
-- distinct non-terminal constructor instead of collapsing into the terminal
-- authority-loss bucket. A constructor-name presence scan cannot tell whether
-- the phrase-to-constructor mapping is right, so the mapping is pinned here
-- behaviourally, driven through a transport that actually fails.
module ModelBCasTransportAdapter
  ( modelBCasTransportAdapterSuite
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
import Prodbox.Lifecycle.ModelBCasTransport
  ( ModelBTransport (..)
  , modelBCasAdapterOverTransport
  , transportFailureCasResult
  , transportFailureObservation
  )
import Prodbox.Lifecycle.StoreLifetime (StoreLifetime (ClusterRetained))
import Prodbox.Minio.EncryptedObject
  ( LogicalConditionalPutResult (..)
  , LogicalObject
  , VersionedLogicalObject (VersionedLogicalObject)
  )
import Prodbox.Minio.ObjectStore (ObjectVersion (ObjectVersion))
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

-- | A 'ModelBTransport' over the fake core — exactly how a real transport wraps
-- the real 'AuthorityObjectCore'.
fakeTransport :: FakeStore -> ModelBTransport
fakeTransport ref =
  ModelBTransport
    { transportObserveObject = \name ->
        first Text.pack <$> readAuthorityObjectCore (fakeCore ref) name
    , transportCasObject = \request ->
        first Text.pack <$> compareAndSwapAuthorityObjectCore (fakeCore ref) request
    }

-- | A transport whose read and write both fail with a supplied detail. This is
-- what makes the @Left@ arms of 'modelBCasAdapterOverTransport' reachable: with
-- a healthy fake they are dead code, so a classifier regression would not
-- surface through the adapter at all.
failingTransport :: Text -> ModelBTransport
failingTransport detail =
  ModelBTransport
    { transportObserveObject = \_ -> pure (Left detail)
    , transportCasObject = \_ -> pure (Left detail)
    }

authority :: LongLivedCheckpointAuthority
authority =
  either (error . show) id $
    mkLongLivedCheckpointAuthority "cluster" "bucket" "namespace" "secret/keyspace"

otherAuthority :: LongLivedCheckpointAuthority
otherAuthority =
  either (error . show) id $
    mkLongLivedCheckpointAuthority "other-cluster" "bucket" "namespace" "secret/keyspace"

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
adapter ref = modelBCasAdapterOverTransport authority (fakeTransport ref)

failingAdapter :: Text -> ModelBCasAdapter 'ClusterRetained IO ByteString
failingAdapter detail = modelBCasAdapterOverTransport authority (failingTransport detail) byteCodec

casUnobservableContains :: String -> ModelBCasResult value -> Bool
casUnobservableContains needle (ModelBCasUnobservable message) = needle `isInfixOf` Text.unpack message
casUnobservableContains _ _ = False

unobservableContains :: String -> ModelBObservation value -> Bool
unobservableContains needle (ModelBUnobservable message) = needle `isInfixOf` Text.unpack message
unobservableContains _ _ = False

isEndpointUnready :: ModelBObservation value -> Bool
isEndpointUnready (ModelBEndpointUnready _) = True
isEndpointUnready _ = False

isUnobservable :: ModelBObservation value -> Bool
isUnobservable (ModelBUnobservable _) = True
isUnobservable _ = False

isCasEndpointUnready :: ModelBCasResult value -> Bool
isCasEndpointUnready (ModelBCasEndpointUnready _) = True
isCasEndpointUnready _ = False

isCasUnobservable :: ModelBCasResult value -> Bool
isCasUnobservable (ModelBCasUnobservable _) = True
isCasUnobservable _ = False

-- | Read failures that must classify as not-yet-ready rather than as a lost
-- authority. The aws-CLI phrasing is the one the shared transient table does
-- not already carry, and is the exact string behind the live bring-up blip.
transientReadDetails :: [Text]
transientReadDetails =
  [ "Could not connect to the endpoint URL: \"http://127.0.0.1:30900/\""
  , "could not connect"
  , "dial tcp 127.0.0.1:30900: connect: connection refused"
  , "connection reset by peer"
  ]

-- | Read failures that must stay terminal. None is a reachability problem, so
-- collapsing them into the retryable bucket would silently retry a request
-- that can never succeed.
terminalReadDetails :: [Text]
terminalReadDetails =
  [ "SignatureDoesNotMatch: the request signature we calculated does not match"
  , "AccessDenied: not authorized to perform s3:GetObject"
  , "HMAC verification failed for object envelope"
  , "failed to decode authority object payload"
  ]

modelBCasTransportAdapterSuite :: SuiteBuilder ()
modelBCasTransportAdapterSuite =
  describe "Sprint 4.53 Model-B endpoint-readiness classifier and shared CAS transport" $ do
    describe "transportFailureObservation (read path)" $ do
      it "classifies endpoint-unreachability as the retryable ModelBEndpointUnready" $
        mapM_
          ( \detail ->
              (detail, transportFailureObservation detail :: ModelBObservation ByteString)
                `shouldSatisfy` (isEndpointUnready . snd)
          )
          transientReadDetails

      it "classifies auth, HMAC, and decode failures as the terminal ModelBUnobservable" $
        mapM_
          ( \detail ->
              (detail, transportFailureObservation detail :: ModelBObservation ByteString)
                `shouldSatisfy` (isUnobservable . snd)
          )
          terminalReadDetails

      it "preserves the original detail text in either arm" $ do
        transportFailureObservation "could not connect"
          `shouldBe` (ModelBEndpointUnready "could not connect" :: ModelBObservation ByteString)
        transportFailureObservation "AccessDenied"
          `shouldBe` (ModelBUnobservable "AccessDenied" :: ModelBObservation ByteString)

    describe "transportFailureCasResult (write path)" $ do
      it "classifies endpoint-unreachability as the retryable ModelBCasEndpointUnready" $
        mapM_
          ( \detail ->
              (detail, transportFailureCasResult detail :: ModelBCasResult ByteString)
                `shouldSatisfy` (isCasEndpointUnready . snd)
          )
          transientReadDetails

      it "classifies auth, HMAC, and decode failures as the terminal ModelBCasUnobservable" $
        mapM_
          ( \detail ->
              (detail, transportFailureCasResult detail :: ModelBCasResult ByteString)
                `shouldSatisfy` (isCasUnobservable . snd)
          )
          terminalReadDetails

    describe "classifier reached through the adapter" $ do
      it "maps a failing transport read to ModelBEndpointUnready" $ do
        result <-
          modelBObserve
            (failingAdapter "Could not connect to the endpoint URL")
            (coordinate "leases/aws-ses")
        result `shouldSatisfy` isEndpointUnready

      it "maps a failing transport write to ModelBCasEndpointUnready" $ do
        result <-
          modelBCompareAndSwap
            (failingAdapter "connection refused")
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result `shouldSatisfy` isCasEndpointUnready

      it "keeps a terminal transport failure terminal through the adapter" $ do
        observed <-
          modelBObserve (failingAdapter "AccessDenied") (coordinate "leases/aws-ses")
        observed `shouldSatisfy` isUnobservable
        applied <-
          modelBCompareAndSwap
            (failingAdapter "AccessDenied")
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        applied `shouldSatisfy` isCasUnobservable

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
      it "refuses corrupt encoding before it reaches the transport" $ do
        -- The encode guard runs ahead of the transport, so a corrupt payload
        -- is refused even when the endpoint is unreachable. This is what makes
        -- the codec-short-circuit fixture unable to cover the classifier.
        result <-
          modelBCompareAndSwap
            ( modelBCasAdapterOverTransport
                authority
                (failingTransport "connection refused")
                encodeRefusedCodec
            )
            (ModelBInitialize (coordinate "leases/aws-ses") "payload")
        result `shouldBe` ModelBCasRefusedCorrupt "encode refused"

    describe "lease-guarded CAS (fail-closed)" $
      it "refuses a guarded write when the guarded lease object is missing" $ do
        ref <- newIORef Map.empty
        let leaseGuard =
              ModelBLeaseGuard
                { modelBLeaseGuardCoordinate = coordinate "leases/aws-ses"
                , modelBLeaseGuardExpectedVersion = version "v1"
                , modelBLeaseGuardOwnerNonceText = "owner"
                , modelBLeaseGuardFencingTokenValue = 1
                }
        result <-
          modelBCompareAndSwap
            (adapter ref byteCodec)
            (ModelBInitializeGuarded (coordinate "smtp-commit/aws-ses") leaseGuard "payload")
        result `shouldSatisfy` casUnobservableContains "lease projection is missing"
