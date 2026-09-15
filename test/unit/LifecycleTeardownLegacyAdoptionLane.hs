{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The bounded legacy-adoption plan-and-apply lane.
--
-- The planner, the permit admission and the receipt repository each have their
-- own suite; what is asserted here is the composition the operator surface
-- drives, and in particular the two properties that only exist once the halves
-- are joined:
--
--   * __The apply pass observes again.__  It does not carry the plan the plan
--     pass produced.  A world that changed between the two passes yields a
--     different document, a different digest, and a refusal of the digest the
--     operator was shown — which is the whole reason the digest is the
--     authorization.
--   * __Nothing is committed on any refusal.__  A stale digest, a wrong
--     audience and an expired freshness each stop before the repository is
--     touched, so a refused adoption leaves no durable record behind.
module LifecycleTeardownLegacyAdoptionLane
  ( lifecycleTeardownLegacyAdoptionLaneSuite
  )
where

import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.LegacyAdoptionCompositionRoot
  ( legacyAdoptionDispatchKeyFor
  )
import Prodbox.ControlPlane.LegacyAdoptionManifestRepository
  ( LegacyAdoptionManifestCommitResult (LegacyAdoptionManifestCommitCreated)
  , LegacyAdoptionManifestReadBack (..)
  , LegacyAdoptionManifestRepository (..)
  , LegacyAdoptionManifestRepositoryError
    ( LegacyAdoptionManifestReceiptMissing
    )
  , adoptedCleanupOwnershipEntryIdentities
  , adoptedCleanupOwnershipStackKey
  , adoptedCleanupOwnershipView
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired, PermitFresh)
  , RunnerRole (AdminActionRunner, ProviderWorker)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry (clientSubmissionKeyText)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsTestProviderStackConfig
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( encodeAwsNativeStackFamilyEvidence
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionLane
import Prodbox.Lifecycle.Teardown.LegacyAdoptionObserver
  ( LegacyAdoptionObservationError (LegacyAdoptionPlanRefused)
  , LegacyAdoptionProviderObserver (..)
  , observeAndPlanLegacyAdoption
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
  ( ObservedResourceIdentity (ObservedResourceIdentity)
  , OwnershipManifestProvenance (OwnershipManifestProvenance)
  , OwnershipManifestVersion (OwnershipManifestVersion)
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestDecisionView (..)
  , OwnershipManifestPurposeValue (LegacyAdoptionOwnershipValue)
  , legacyAdoptionPlanDigestText
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( providerDispatchSubmissionKey
  )
import Prodbox.Lifecycle.Teardown.Registry
import System.IO.Unsafe (unsafePerformIO)
import TestSupport

lifecycleTeardownLegacyAdoptionLaneSuite :: SuiteBuilder ()
lifecycleTeardownLegacyAdoptionLaneSuite =
  describe "Sprint 7.42 bounded legacy-adoption lane" $ do
    it "names the three per-run stacks and no retained shared infrastructure" $ do
      -- `aws-ses` is the one stack nothing may reap, and an adoption of it
      -- would record per-run cleanup ownership over it.
      map adoptableLegacyStackKey [minBound .. maxBound]
        `shouldBe` [AwsEksKey, AwsEksSubzoneKey, AwsTestKey]
      map adoptableLegacyStackName [minBound .. maxBound]
        `shouldBe` ["eks", "aws-subzone", "test"]

    it "gives each family member its own Authority submission key" $ do
      -- The submission key is the Authority's idempotency identity. One key
      -- for the whole family would make the second, third and fourth
      -- observations replay the first's evidence, and the planner would see
      -- four answers about one resource -- an ambiguity it cannot detect,
      -- because every row would be well formed.
      let keys =
            [ fmap
                (clientSubmissionKeyText . providerDispatchSubmissionKey)
                (legacyAdoptionDispatchKeyFor AdoptAwsTest intent)
            | intent <- familyIntents
            ]
      length keys `shouldBe` 4
      keys `shouldSatisfy` all isRight
      length (nub keys) `shouldBe` 4
      -- And stable: repeating the plan pass replays the Authority's retained
      -- observation rather than allocating a new identity for one question.
      [ fmap
          (clientSubmissionKeyText . providerDispatchSubmissionKey)
          (legacyAdoptionDispatchKeyFor AdoptAwsTest intent)
        | intent <- familyIntents
        ]
        `shouldBe` keys
      -- A different stack is a different adoption.
      case (familyIntents, keys) of
        (firstIntent : _, firstKey : _) ->
          fmap
            (clientSubmissionKeyText . providerDispatchSubmissionKey)
            (legacyAdoptionDispatchKeyFor AdoptAwsEks firstIntent)
            `shouldNotBe` firstKey
        _ -> expectationFailure "the eks family observed no intents"

    it "renders the candidate document and its digest without committing" $ do
      world <- newWorld ["vol-legacy-1"]
      sources <- newSources world
      rendered <-
        renderLegacyAdoptionCandidatePlan sources ExplicitPerRunSurface request
      case rendered of
        Left err -> expectationFailure (show err)
        Right plan -> do
          renderedLegacyAdoptionStackKey plan `shouldBe` AwsTestKey
          renderedLegacyAdoptionDocument plan
            `shouldSatisfy` Text.isInfixOf "legacy-adoption-plan/v1"
          renderedLegacyAdoptionDocument plan
            `shouldSatisfy` Text.isInfixOf "vol-legacy-1"
          Text.length
            (legacyAdoptionPlanDigestText (renderedLegacyAdoptionDigest plan))
            `shouldBe` 64
          map legacyAdoptionEntryKey (renderedLegacyAdoptionEntries plan)
            `shouldBe` legacyAdoptionExpectedFamily AwsTestKey
      -- The plan pass is read-only all the way down.
      readIORef (worldCommits world) `shouldReturn` 0
      readIORef (worldReadBacks world) `shouldReturn` 0

    it "adopts under the exact digest the plan pass produced" $ do
      world <- newWorld ["vol-legacy-1"]
      sources <- newSources world
      digest <- mustDigest sources world
      adopted <-
        applyConfirmedLegacyAdoption
          sources
          ExplicitPerRunSurface
          request
          (permitRequest AdminActionRunner AwsTestKey digest)
      case adopted of
        Left err -> expectationFailure (show err)
        Right ownership -> do
          adoptedCleanupOwnershipStackKey ownership `shouldBe` AwsTestKey
          -- The receipt says it is an adoption. That is the field the
          -- create-side minter refuses on.
          case adoptedCleanupOwnershipView ownership of
            OwnershipManifestDecisionComplete purpose _ version -> do
              purpose `shouldBe` LegacyAdoptionOwnershipValue ExplicitPerRun
              version `shouldBe` fixtureVersion
            OwnershipManifestDecisionObservation _ ->
              expectationFailure "an exact read-back produced observation-only evidence"
          adoptedCleanupOwnershipEntryIdentities AwsTestKey ownership
            `shouldBe` Just [ObservedResourceIdentity "vol-legacy-1"]
      readIORef (worldCommits world) `shouldReturn` 1
      readIORef (worldReadBacks world) `shouldReturn` 1

    it "refuses the operator's digest when the world moved between passes" $ do
      -- This is the property the two-pass shape exists for. The operator
      -- confirmed a document; the apply pass renders a different one because
      -- the provider now answers differently, and the confirmation does not
      -- transfer.
      world <- newWorld ["vol-legacy-1"]
      sources <- newSources world
      staleDigest <- mustDigest sources world
      writeIORef (worldEbsIdentities world) ["vol-legacy-2"]
      adopted <-
        applyConfirmedLegacyAdoption
          sources
          ExplicitPerRunSurface
          request
          (permitRequest AdminActionRunner AwsTestKey staleDigest)
      case adopted of
        Right _ -> expectationFailure "a stale digest authorized an adoption"
        Left (LegacyAdoptionLaneConfirmationRefused refusal) ->
          refusal `shouldSatisfy` isDigestMismatch
        Left err -> expectationFailure ("unexpected refusal: " <> show err)
      readIORef (worldCommits world) `shouldReturn` 0

    it "refuses a permit for another stack, another audience, or a stale confirmation" $ do
      world <- newWorld ["vol-legacy-1"]
      sources <- newSources world
      digest <- mustDigest sources world
      wrongStack <-
        applyConfirmedLegacyAdoption
          sources
          ExplicitPerRunSurface
          request
          (permitRequest AdminActionRunner AwsEksKey digest)
      wrongStack `shouldSatisfy` refusesConfirmation
      wrongAudience <-
        applyConfirmedLegacyAdoption
          sources
          ExplicitPerRunSurface
          request
          (permitRequest ProviderWorker AwsTestKey digest)
      wrongAudience
        `shouldSatisfy` refusesWith
          (LegacyAdoptionLanePermitRefused (AdminLegacyPermitWrongAudience ProviderWorker))
      expiredSources <- newSourcesWith world PermitExpired
      expired <-
        applyConfirmedLegacyAdoption
          expiredSources
          ExplicitPerRunSurface
          request
          (permitRequest AdminActionRunner AwsTestKey digest)
      expired
        `shouldSatisfy` refusesWith
          (LegacyAdoptionLanePermitRefused AdminLegacyPermitExpired)
      readIORef (worldCommits world) `shouldReturn` 0

    it "refuses the whole family rather than adopting a shorter one" $ do
      world <- newWorld ["vol-legacy-1"]
      writeIORef (worldObservable world) False
      sources <- newSources world
      rendered <-
        renderLegacyAdoptionCandidatePlan sources ExplicitPerRunSurface request
      case rendered of
        Right _ -> expectationFailure "an unobservable family produced a plan"
        Left (LegacyAdoptionLaneObservationRefused (LegacyAdoptionPlanRefused refusal)) ->
          refusal
            `shouldBe` LegacyAdoptionCandidatesUnobservable
              (take 1 (legacyAdoptionExpectedFamily AwsTestKey))
        Left err -> expectationFailure ("unexpected refusal: " <> show err)

    it "reports a receipt that did not read back, and mints nothing from it" $ do
      world <- newWorld ["vol-legacy-1"]
      sources <- newSources world
      digest <- mustDigest sources world
      writeIORef (worldReadBackPresent world) False
      adopted <-
        applyConfirmedLegacyAdoption
          sources
          ExplicitPerRunSurface
          request
          (permitRequest AdminActionRunner AwsTestKey digest)
      adopted
        `shouldSatisfy` refusesWith
          (LegacyAdoptionLaneReceiptRefused LegacyAdoptionManifestReceiptMissing)

    it "admits only a digest of the shape the planner produces" $ do
      -- A transcription error and a plan that changed are different faults,
      -- and the operator surface must be able to say which happened.
      fmap legacyAdoptionPlanDigestText (mkLegacyAdoptionPlanDigest wellFormedDigest)
        `shouldBe` Right wellFormedDigest
      mkLegacyAdoptionPlanDigest (Text.toUpper wellFormedDigest)
        `shouldBe` Left
          (LegacyAdoptionPlanDigestMalformed (Text.toUpper wellFormedDigest))
      mkLegacyAdoptionPlanDigest (Text.take 63 wellFormedDigest)
        `shouldBe` Left
          (LegacyAdoptionPlanDigestMalformed (Text.take 63 wellFormedDigest))
      mkLegacyAdoptionPlanDigest ""
        `shouldBe` Left (LegacyAdoptionPlanDigestMalformed "")

wellFormedDigest :: Text
wellFormedDigest = Text.replicate 64 "a"

-- | The four read-only intents an adoption of the eks family issues, taken
-- from the real observer rather than authored here.
familyIntents :: [ProviderIntent]
familyIntents = unsafePerformIO $ do
  collected <- newIORef []
  let observer = LegacyAdoptionProviderObserver $ \intent -> do
        modifyIORef' collected (<> [intent])
        pure (Left "fixture collects intents and answers nothing")
  _ <-
    observeAndPlanLegacyAdoption
      ExplicitPerRunSurface
      AwsEksKey
      eksScope
      (ObservationRevision 91)
      eksConfig
      observer
  readIORef collected
{-# NOINLINE familyIntents #-}

eksScope :: ObservationEvidenceScope
eksScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "legacy-adoption-lane-run")
    (LinuxRke2FoundationId "home-rke2")
    ( Just
        ( AwsScope
            (AwsAccountId "123456789012")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

eksConfig :: ProviderStackConfig
eksConfig = mustRight (mkAwsEksProviderStackConfig "203.0.113.1/32")

-- ---------------------------------------------------------------------------
-- Fixture world
-- ---------------------------------------------------------------------------

-- | The mutable provider facts the two passes read, plus the counters that
-- prove where a refusal stopped.
data FixtureWorld = FixtureWorld
  { worldEbsIdentities :: !(IORef [Text])
  , worldObservable :: !(IORef Bool)
  , worldReadBackPresent :: !(IORef Bool)
  , worldSlot :: !(IORef (Maybe ByteString))
  , worldCommits :: !(IORef Int)
  , worldReadBacks :: !(IORef Int)
  }

newWorld :: [Text] -> IO FixtureWorld
newWorld identities =
  FixtureWorld
    <$> newIORef identities
    <*> newIORef True
    <*> newIORef True
    <*> newIORef Nothing
    <*> newIORef 0
    <*> newIORef 0

newSources :: FixtureWorld -> IO (LegacyAdoptionSources IO)
newSources world = newSourcesWith world PermitFresh

newSourcesWith :: FixtureWorld -> PermitFreshness -> IO (LegacyAdoptionSources IO)
newSourcesWith world freshness =
  pure
    LegacyAdoptionSources
      { legacyAdoptionObserver = LegacyAdoptionProviderObserver (observe world)
      , legacyAdoptionRepository = fixtureRepository world
      , observeLegacyAdoptionPermitFreshness = pure freshness
      }

observe
  :: FixtureWorld -> ProviderIntent -> IO (Either Text ProviderIntentExecutionResult)
observe world intent = do
  observable <- readIORef (worldObservable world)
  if not observable
    then pure (Left "fixture provider is unavailable")
    else do
      identities <- readIORef (worldEbsIdentities world)
      pure
        ( Right
            ( ProviderIntentExecutionObserved
                (providerIntentCoordinate intent)
                ( case intent of
                    ObserveNativeStackFamily ref _ ->
                      mustRight (encodeAwsNativeStackFamilyEvidence ref identities)
                    _ -> "fixture received an intent outside the closed family"
                )
            )
        )

fixtureRepository :: FixtureWorld -> LegacyAdoptionManifestRepository IO
fixtureRepository world =
  LegacyAdoptionManifestRepository
    { commitLegacyAdoptionManifestReceipt = \_ bytes -> do
        modifyIORef' (worldCommits world) (+ 1)
        writeIORef (worldSlot world) (Just bytes)
        pure LegacyAdoptionManifestCommitCreated
    , independentlyReadBackLegacyAdoptionManifestReceipt = \_ -> do
        modifyIORef' (worldReadBacks world) (+ 1)
        present <- readIORef (worldReadBackPresent world)
        stored <- readIORef (worldSlot world)
        pure $ case (present, stored) of
          (True, Just bytes) ->
            LegacyAdoptionManifestReadBackPresent
              fixtureProvenance
              fixtureVersion
              bytes
          _ -> LegacyAdoptionManifestReadBackMissing
    }

-- | The digest the plan pass shows an operator, taken through the same lane the
-- operator surface calls.
mustDigest :: LegacyAdoptionSources IO -> FixtureWorld -> IO Text
mustDigest sources world = do
  rendered <- renderLegacyAdoptionCandidatePlan sources ExplicitPerRunSurface request
  writeIORef (worldCommits world) 0
  writeIORef (worldReadBacks world) 0
  case rendered of
    Left err -> error ("fixture plan pass refused: " <> show err)
    Right plan ->
      pure (legacyAdoptionPlanDigestText (renderedLegacyAdoptionDigest plan))

permitRequest
  :: RunnerRole -> RegisteredResourceKey -> Text -> AdminLegacyAdoptionPermitRequest
permitRequest audience stackKey digest =
  AdminLegacyAdoptionPermitRequest
    { adminLegacyPermitRequestAudience = audience
    , adminLegacyPermitRequestStackKey = stackKey
    , adminLegacyPermitRequestPlanDigest =
        mustRight (mkLegacyAdoptionPlanDigest digest)
    , adminLegacyPermitRequestNonce = "legacy-adoption:test:" <> digest
    }

request :: LegacyAdoptionRequest
request =
  LegacyAdoptionRequest
    { legacyAdoptionRequestStackKey = AwsTestKey
    , legacyAdoptionRequestScope = perRunScope
    , legacyAdoptionRequestRevision = ObservationRevision 91
    , legacyAdoptionRequestProviderConfig = testConfig
    }

perRunScope :: ObservationEvidenceScope
perRunScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "legacy-adoption-lane-run")
    (LinuxRke2FoundationId "home-rke2")
    ( Just
        ( AwsScope
            (AwsAccountId "123456789012")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

testConfig :: ProviderStackConfig
testConfig = mustRight (mkAwsTestProviderStackConfig "203.0.113.1/32")

fixtureProvenance :: OwnershipManifestProvenance
fixtureProvenance = OwnershipManifestProvenance "fixture/legacy-adoption-lane"

fixtureVersion :: OwnershipManifestVersion
fixtureVersion = OwnershipManifestVersion "model-b-v1"

isDigestMismatch :: LegacyAdoptionConfirmationRefusal -> Bool
isDigestMismatch refusal = case refusal of
  LegacyAdoptionConfirmationDigestMismatch {} -> True
  LegacyAdoptionConfirmationStackMismatch {} -> False

refusesConfirmation :: Either LegacyAdoptionLaneError value -> Bool
refusesConfirmation outcome = case outcome of
  Left (LegacyAdoptionLaneConfirmationRefused _) -> True
  _ -> False

refusesWith
  :: LegacyAdoptionLaneError -> Either LegacyAdoptionLaneError value -> Bool
refusesWith expected outcome = case outcome of
  Left actual -> actual == expected
  Right _ -> False

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight value = case value of
  Right result -> result
  Left err -> error ("expected Right, got " <> show err)
