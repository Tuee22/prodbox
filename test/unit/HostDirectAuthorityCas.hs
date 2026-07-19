{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.51 Increment B (Stage A): the shared 'AuthorityObjectCore' CAS/read/
-- lease-guard orchestration, driven over an in-memory conditional-put fake (no
-- Vault, no MinIO). Because the daemon and the host-direct CLI both delegate to
-- THIS core, proving the core's semantics proves both transports' orchestration
-- at once. The byte-identity of the physical envelopes is structural (both build
-- 'AuthorityCore' from the same encrypted-object primitives) and is proven live
-- by the Standard-O AWS-substrate run; here we pin the conditional-put semantics
-- and the fail-closed lease-guard ladder.
module HostDirectAuthorityCas
  ( hostDirectAuthorityCasSuite
  )
where

import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Prodbox.Gateway.ObjectStore
  ( AuthorityObjectCasRequest (..)
  , AuthorityObjectCasResponse (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectObservation (..)
  )
import Prodbox.Lifecycle.AuthorityObjectCore
  ( AuthorityCore (..)
  , compareAndSwapAuthorityObjectCore
  , readAuthorityObjectCore
  )
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

-- | An in-memory 'AuthorityCore' with real conditional-put semantics: if-absent
-- applies only when the object is missing; if-version applies only when the
-- stored version matches; a successful put bumps the version; every read returns
-- the current store version (never a put echo).
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
  toVersioned (bytes, version) = VersionedLogicalObject bytes version

casRequest
  :: Text -> Maybe Text -> Maybe AuthorityObjectLeaseGuard -> ByteString -> AuthorityObjectCasRequest
casRequest logicalName expectedVersion leaseGuard payload =
  AuthorityObjectCasRequest
    { authorityObjectCasLogicalName = logicalName
    , authorityObjectCasExpectedVersion = expectedVersion
    , authorityObjectCasLeaseGuard = leaseGuard
    , authorityObjectCasPayload = payload
    , authorityObjectCasLoopbackNodePortVerified = True
    }

applyFresh :: FakeStore -> Text -> ByteString -> IO (Either String AuthorityObjectCasResponse)
applyFresh ref logicalName payload =
  compareAndSwapAuthorityObjectCore (fakeCore ref) (casRequest logicalName Nothing Nothing payload)

leftContains :: String -> Either String a -> Bool
leftContains needle (Left message) = needle `isInfixOf` message
leftContains _ _ = False

hostDirectAuthorityCasSuite :: SuiteBuilder ()
hostDirectAuthorityCasSuite =
  describe "Sprint 4.51-B AuthorityObjectCore" $ do
    describe "read" $ do
      it "reads a missing object as AuthorityObjectMissing" $ do
        ref <- newIORef Map.empty
        result <- readAuthorityObjectCore (fakeCore ref) "leases/aws-ses"
        result `shouldBe` Right AuthorityObjectMissing
      it "reads an applied object back at its store version" $ do
        ref <- newIORef Map.empty
        _ <- applyFresh ref "leases/aws-ses" "payload"
        result <- readAuthorityObjectCore (fakeCore ref) "leases/aws-ses"
        result `shouldBe` Right (AuthorityObjectObserved "v1" "payload")

    describe "conditional put" $ do
      it "if-absent on a missing object applies" $ do
        ref <- newIORef Map.empty
        result <- applyFresh ref "leases/aws-ses" "payload"
        result `shouldBe` Right (AuthorityObjectCasApplied "v1")
      it "if-absent on a present object conflicts (with the current observation)" $ do
        ref <- newIORef Map.empty
        _ <- applyFresh ref "leases/aws-ses" "payload"
        result <- applyFresh ref "leases/aws-ses" "payload2"
        result `shouldBe` Right (AuthorityObjectCasConflict (AuthorityObjectObserved "v1" "payload"))
      it "if-version on a matching version applies and bumps" $ do
        ref <- newIORef Map.empty
        _ <- applyFresh ref "leases/aws-ses" "payload"
        result <-
          compareAndSwapAuthorityObjectCore
            (fakeCore ref)
            (casRequest "leases/aws-ses" (Just "v1") Nothing "payload2")
        result `shouldBe` Right (AuthorityObjectCasApplied "v1*")
      it "if-version on a mismatched version conflicts" $ do
        ref <- newIORef Map.empty
        _ <- applyFresh ref "leases/aws-ses" "payload"
        result <-
          compareAndSwapAuthorityObjectCore
            (fakeCore ref)
            (casRequest "leases/aws-ses" (Just "stale") Nothing "payload2")
        result `shouldBe` Right (AuthorityObjectCasConflict (AuthorityObjectObserved "v1" "payload"))

    describe "lease-guard ladder (fail-closed)" $ do
      it "refuses when the guarded lease object is missing" $ do
        ref <- newIORef Map.empty
        let guard = AuthorityObjectLeaseGuard "leases/aws-ses" "v1" "owner" 1
        result <-
          compareAndSwapAuthorityObjectCore
            (fakeCore ref)
            (casRequest "smtp-commit/aws-ses" Nothing (Just guard) "payload")
        result `shouldSatisfy` leftContains "lease projection is missing"
      it "refuses when the guarded lease object version has changed" $ do
        ref <- newIORef Map.empty
        _ <- applyFresh ref "leases/aws-ses" "lease-bytes"
        let guard = AuthorityObjectLeaseGuard "leases/aws-ses" "stale-version" "owner" 1
        result <-
          compareAndSwapAuthorityObjectCore
            (fakeCore ref)
            (casRequest "smtp-commit/aws-ses" Nothing (Just guard) "payload")
        result `shouldSatisfy` leftContains "lease object version changed"
      it "refuses when the guarded lease projection does not decode" $ do
        ref <- newIORef Map.empty
        _ <- applyFresh ref "leases/aws-ses" "not-a-valid-lease-projection"
        let guard = AuthorityObjectLeaseGuard "leases/aws-ses" "v1" "owner" 1
        result <-
          compareAndSwapAuthorityObjectCore
            (fakeCore ref)
            (casRequest "smtp-commit/aws-ses" Nothing (Just guard) "payload")
        result `shouldSatisfy` leftContains "invalid lease projection"
