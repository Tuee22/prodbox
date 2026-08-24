{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneLegacyAdoptionManifestRepository
  ( controlPlaneLegacyAdoptionManifestRepositorySuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.LegacyAdoptionManifestRepository
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitFresh)
  , RunnerRole (AdminActionRunner)
  )
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
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

controlPlaneLegacyAdoptionManifestRepositorySuite :: SuiteBuilder ()
controlPlaneLegacyAdoptionManifestRepositorySuite =
  describe "Sprint 7.36 confirmed legacy-adoption receipt repository" $ do
    it "recovers a response-lost commit only through independent exact readback" $ do
      slot <- newIORef Nothing
      commits <- newIORef (0 :: Int)
      readBacks <- newIORef (0 :: Int)
      identities <- newIORef []
      let repository =
            LegacyAdoptionManifestRepository
              { commitLegacyAdoptionManifestReceipt = \identity bytes -> do
                  modifyIORef' commits (+ 1)
                  modifyIORef' identities (<> [identity])
                  writeIORef slot (Just bytes)
                  pure
                    ( LegacyAdoptionManifestCommitResponseLost
                        (ObservationFailure "response lost after applied CAS")
                    )
              , independentlyReadBackLegacyAdoptionManifestReceipt = \identity -> do
                  modifyIORef' readBacks (+ 1)
                  modifyIORef' identities (<> [identity])
                  stored <- readIORef slot
                  pure $ case stored of
                    Nothing -> LegacyAdoptionManifestReadBackMissing
                    Just bytes ->
                      LegacyAdoptionManifestReadBackPresent
                        fixtureProvenance
                        fixtureVersion
                        bytes
              }
      result <-
        commitAndReadBackConfirmedLegacyAdoptionManifest
          repository
          ExplicitPerRunSurface
          confirmedPlan
      fmap ownershipManifestDecisionView result
        `shouldBe` Right
          (OwnershipManifestDecisionComplete fixtureProvenance fixtureVersion)
      readIORef commits `shouldReturn` 1
      readIORef readBacks `shouldReturn` 1
      observedIdentities <- readIORef identities
      observedIdentities `shouldSatisfy` hasMatchingManifestIdentities

    it "refuses every non-exact independent readback even after commit success" $ do
      let write =
            mustRight
              (confirmedLegacyAdoptionManifestWrite ExplicitPerRunSurface confirmedPlan)
          expected = confirmedLegacyAdoptionManifestWriteReceiptBytes write
          cases =
            [
              ( LegacyAdoptionManifestReadBackMissing
              , LegacyAdoptionManifestReceiptMissing
              )
            ,
              ( LegacyAdoptionManifestReadBackCorrupt "bad envelope"
              , LegacyAdoptionManifestReceiptCorrupt "bad envelope"
              )
            ,
              ( LegacyAdoptionManifestReadBackUnobservable
                  (ObservationFailure "authority offline")
              , LegacyAdoptionManifestReceiptUnobservable
                  (ObservationFailure "authority offline")
              )
            ,
              ( LegacyAdoptionManifestReadBackUnbounded
                  maximumLegacyAdoptionManifestReceiptBytes
                  (maximumLegacyAdoptionManifestReceiptBytes + 1)
              , LegacyAdoptionManifestReceiptUnbounded
                  maximumLegacyAdoptionManifestReceiptBytes
                  (maximumLegacyAdoptionManifestReceiptBytes + 1)
              )
            ,
              ( LegacyAdoptionManifestReadBackPresent
                  fixtureProvenance
                  fixtureVersion
                  (ByteString.snoc expected 0)
              , LegacyAdoptionManifestReceiptMismatch
              )
            ]
      mapM_
        ( \(readBack, expectedError) -> do
            result <-
              commitAndReadBackConfirmedLegacyAdoptionManifest
                (fixedRepository readBack)
                ExplicitPerRunSurface
                confirmedPlan
            case result of
              Left actualError -> actualError `shouldBe` expectedError
              Right _ -> expectationFailure "non-exact readback minted cleanup evidence"
        )
        cases

    it "uses an immutable Model-B slot for create, replay, and independent readback" $ do
      stored <- newIORef Nothing
      writes <- newIORef (0 :: Int)
      let adapter = modelBFixture stored writes
          repository =
            modelBLegacyAdoptionManifestRepository fixtureAuthority adapter
      firstResult <-
        commitAndReadBackConfirmedLegacyAdoptionManifest
          repository
          ExplicitPerRunSurface
          confirmedPlan
      secondResult <-
        commitAndReadBackConfirmedLegacyAdoptionManifest
          repository
          ExplicitPerRunSurface
          confirmedPlan
      fmap ownershipManifestDecisionView firstResult
        `shouldBe` Right
          (OwnershipManifestDecisionComplete modelBProvenance fixtureVersion)
      fmap ownershipManifestDecisionView secondResult
        `shouldBe` Right
          (OwnershipManifestDecisionComplete modelBProvenance fixtureVersion)
      readIORef writes `shouldReturn` 1

    it "bounds the Model-B codec and rejects empty receipts" $ do
      let bytes =
            confirmedLegacyAdoptionManifestWriteReceiptBytes
              ( mustRight
                  (confirmedLegacyAdoptionManifestWrite ExplicitPerRunSurface confirmedPlan)
              )
      encodeModelBValue legacyAdoptionManifestModelBCodec bytes `shouldBe` Right bytes
      decodeModelBValue legacyAdoptionManifestModelBCodec bytes `shouldBe` Right bytes
      encodeModelBValue legacyAdoptionManifestModelBCodec ByteString.empty
        `shouldSatisfy` isLeft
      decodeModelBValue
        legacyAdoptionManifestModelBCodec
        (ByteString.replicate (maximumLegacyAdoptionManifestReceiptBytes + 1) 0)
        `shouldSatisfy` isLeft

fixedRepository
  :: LegacyAdoptionManifestReadBack
  -> LegacyAdoptionManifestRepository IO
fixedRepository readBack =
  LegacyAdoptionManifestRepository
    { commitLegacyAdoptionManifestReceipt =
        \_ _ -> pure LegacyAdoptionManifestCommitCreated
    , independentlyReadBackLegacyAdoptionManifestReceipt = \_ -> pure readBack
    }

modelBFixture
  :: IORef (Maybe ByteString)
  -> IORef Int
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
modelBFixture stored writes =
  ModelBCasAdapter
    { modelBObserve = \_ -> do
        value <- readIORef stored
        pure $ case value of
          Nothing -> ModelBMissing
          Just bytes -> ModelBObserved fixtureModelBVersion bytes
    , modelBCompareAndSwap = compareAndSwap
    }
 where
  compareAndSwap request = case request of
    ModelBInitialize _ bytes -> do
      current <- readIORef stored
      case current of
        Nothing -> do
          modifyIORef' writes (+ 1)
          writeIORef stored (Just bytes)
          pure (ModelBCasApplied fixtureModelBVersion bytes)
        Just existing ->
          pure (ModelBCasConflict (ModelBObserved fixtureModelBVersion existing))
    ModelBReplace {} -> pure (ModelBCasRefusedCorrupt "replace is forbidden")
    ModelBInitializeGuarded {} ->
      pure (ModelBCasRefusedCorrupt "guarded initialize is forbidden")
    ModelBReplaceGuarded {} ->
      pure (ModelBCasRefusedCorrupt "guarded replace is forbidden")

hasMatchingManifestIdentities :: [LegacyAdoptionManifestIdentity] -> Bool
hasMatchingManifestIdentities values = case values of
  [committed, readBack] ->
    committed == readBack
      && legacyAdoptionManifestIdentityStackKey committed == AwsTestKey
      && legacyAdoptionManifestIdentityScope committed == perRunScope
      && "authority/legacy-adoption-manifests/"
        `isTextPrefixOf` legacyAdoptionManifestLogicalName committed
  _ -> False

confirmedPlan :: ConfirmedLegacyAdoptionPlan 'ExplicitPerRun
confirmedPlan =
  mustRight (confirmLegacyAdoptionPlan permit plan)
 where
  permit =
    mustRight
      ( admitAdminLegacyAdoptionPermit
          PermitFresh
          AdminLegacyAdoptionPermitRequest
            { adminLegacyPermitRequestAudience = AdminActionRunner
            , adminLegacyPermitRequestStackKey = AwsTestKey
            , adminLegacyPermitRequestPlanDigest = legacyAdoptionPlanDigestOf plan
            , adminLegacyPermitRequestNonce = "legacy-receipt-nonce"
            }
      )

plan :: LegacyAdoptionPlan 'ExplicitPerRun
plan =
  mustRight
    ( planLegacyAdoption
        ExplicitPerRunSurface
        AwsTestKey
        perRunScope
        [ exactResourceObservationFor
            (mustIdentity AwsTestKey)
            (ObservationRevision 74)
            perRunScope
            ( ExactResourceAbsent
                (AbsenceEvidence "fixture observed registered stack absence")
            )
        ]
    )

perRunScope :: ObservationEvidenceScope
perRunScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "legacy-adoption-receipt-run")
    (LinuxRke2FoundationId "home-rke2")
    ( Just
        ( AwsScope
            (AwsAccountId "123456789012")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

fixtureAuthority :: LongLivedCheckpointAuthority
fixtureAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-rke2"
        "retained-bucket"
        "prodbox/lifecycle"
        "secret/prodbox"
    )

fixtureModelBVersion :: ModelBObjectVersion
fixtureModelBVersion = mustRight (mkModelBObjectVersion "model-b-v1")

fixtureProvenance :: OwnershipManifestProvenance
fixtureProvenance = OwnershipManifestProvenance "fixture/model-b"

modelBProvenance :: OwnershipManifestProvenance
modelBProvenance =
  OwnershipManifestProvenance "lifecycle-authority/model-b/legacy-adoption/v1"

fixtureVersion :: OwnershipManifestVersion
fixtureVersion = OwnershipManifestVersion "model-b-v1"

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("unregistered fixture key " <> show key)

isLeft :: Either value right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

isTextPrefixOf :: String -> Text -> Bool
isTextPrefixOf prefix value =
  Text.pack prefix `Text.isPrefixOf` value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
