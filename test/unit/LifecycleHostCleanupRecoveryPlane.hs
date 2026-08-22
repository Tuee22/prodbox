{-# LANGUAGE OverloadedStrings #-}

module LifecycleHostCleanupRecoveryPlane
  ( lifecycleHostCleanupRecoveryPlaneSuite
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.LocalRke2RecoveryState (LocalRke2RecoveryStateView (..))
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownRecovery
  , OrdinaryTeardownTargetAgent (OrdinaryTeardownWithoutTargetAgent)
  , ordinaryTeardownRecovery
  , renderOrdinaryTeardownRecoveryError
  )
import Prodbox.Config.OrdinaryTeardownRepair
  ( RetainedArtifactArchitecture (..)
  , RetainedArtifactEntry (..)
  , RetainedArtifactInventory
  , RetainedArtifactKind (..)
  , renderRetainedArtifactInventoryError
  , retainedArtifactInventory
  , retainedArtifactKindText
  )
import Prodbox.Lifecycle.HostCleanupRecoveryPlane
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (..)
  , HostRecoveryPlaneCheck (..)
  , HostRecoveryPlaneCheckResult (..)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , DurableObservationRunScope (..)
  , LifecycleOperation (ReconcileDesiredAbsent)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.RecoveryRepairExecution
  ( RecoveryRepairBoundary (..)
  , RecoveryRepairRun (..)
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactLocator (..)
  , RetainedArtifactMember (..)
  , RetainedArtifactMemberDigest (..)
  , RetainedArtifactSourceCatalog
  , RetainedArtifactSourceEntry (..)
  , RetainedArtifactStoreObservation (..)
  , renderRetainedArtifactSourceError
  , retainedArtifactSourceCatalog
  )
import TestSupport

lifecycleHostCleanupRecoveryPlaneSuite :: SuiteBuilder ()
lifecycleHostCleanupRecoveryPlaneSuite =
  describe "Sprint 4.86 host cleanup recovery-plane arms" $ do
    describe "reading the plane back" $ do
      it "maps each observation onto one check answer without collapsing any" $ do
        let regression = fixedHostRecoveryPlaneRegression fixtureScope
        hostRecoveryPlaneRegressionHealthyIsAvailable regression `shouldBe` True
        hostRecoveryPlaneRegressionStoppedIsUnavailable regression `shouldBe` True
        hostRecoveryPlaneRegressionAbsentIsUnavailable regression `shouldBe` True
        hostRecoveryPlaneRegressionUnreadIsUnobservable regression `shouldBe` True

      it "scopes the check by the record it was given" $ do
        let regression = fixedHostRecoveryPlaneRegression fixtureScope
        hostRecoveryPlaneRegressionCheckCarriesGivenScope regression `shouldBe` True

      it "keeps a stopped substrate distinct from one it could not read" $ do
        -- The runner has separate errors for the two, and the repair a stopped
        -- substrate needs is not the repair an unread one needs -- an unread
        -- substrate selects no repair at all.
        detailOf (resultFor (Right LocalRke2RecoveryStopped))
          `shouldSatisfy` Text.isInfixOf "stopped"
        detailOf (resultFor (Right LocalRke2RecoveryAbsent))
          `shouldSatisfy` Text.isInfixOf "absent"
        detailOf (resultFor (Left "systemd did not answer"))
          `shouldSatisfy` Text.isInfixOf "unobservable"

    describe "re-establishing it" $ do
      it "applies the repair the observed state needs" $ do
        (establishment, calls) <- establishWith (Right LocalRke2RecoveryAbsent) exactStore alwaysOk
        establishment `shouldSatisfy` isApplied
        calls `shouldSatisfy` (not . null)
        take 1 calls `shouldBe` ["install"]

      it "does not claim availability from an applied repair" $ do
        -- The whole separation: the mutation says what it did, and the
        -- read-back decides whether the plane is up.
        (establishment, _) <- establishWith (Right LocalRke2RecoveryAbsent) exactStore alwaysOk
        hostRecoveryPlaneEstablishmentEffect establishment `shouldBe` HostCleanupEffectApplied

      it "stops at the first failed step and carries the unattempted tail" $ do
        (establishment, calls) <-
          establishWith (Right LocalRke2RecoveryAbsent) exactStore (failing "install")
        establishment `shouldSatisfy` isStopped
        calls `shouldBe` ["install"]
        unattemptedOf establishment `shouldSatisfy` (> 0)
        hostRecoveryPlaneEstablishmentEffect establishment `shouldSatisfy` isRefused

      it "refuses a repair the retained store cannot admit, before any boundary call" $ do
        (establishment, calls) <-
          establishWith (Right LocalRke2RecoveryAbsent) emptyStore alwaysOk
        establishment `shouldSatisfy` isInadmissible
        calls `shouldBe` []
        hostRecoveryPlaneEstablishmentEffect establishment `shouldSatisfy` isRefused

      it "selects no repair at all for a substrate it could not observe" $ do
        -- A plan is rendered for an observed state, so an unobserved substrate
        -- must not fall back to one.
        (establishment, calls) <-
          establishWith (Left "systemd did not answer") exactStore alwaysOk
        establishment `shouldSatisfy` isUnobservableState
        calls `shouldBe` []
        hostRecoveryPlaneEstablishmentEffect establishment `shouldSatisfy` isRefused

      it "renders every attempt as an operator-readable line" $ do
        mapM_
          ( \attempt ->
              renderHostRecoveryPlaneEstablishment attempt
                `shouldSatisfy` Text.isInfixOf "recovery-plane"
          )
          [ HostRecoveryPlaneRepairApplied emptyRun
          , HostRecoveryPlaneRepairStopped emptyRun "install failed"
          , HostRecoveryPlaneRepairInadmissible "retained bytes drifted"
          , HostRecoveryPlaneStateUnobservable "systemd did not answer"
          ]

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

resultFor :: Either Text LocalRke2RecoveryStateView -> HostRecoveryPlaneCheckResult
resultFor = hostRecoveryPlaneCheckResult . hostRecoveryPlaneCheckFor fixtureScope

detailOf :: HostRecoveryPlaneCheckResult -> Text
detailOf result = case result of
  HostRecoveryPlaneAvailable -> "available"
  HostRecoveryPlaneUnavailable failure -> Text.pack (show failure)
  HostRecoveryPlaneUnobservable failure -> Text.pack (show failure)

fixtureScope :: ObservationEvidenceScope
fixtureScope =
  mkObservationEvidenceScope
    Cascade
    (RegistryRevision "fixture-revision")
    (DurableObservationRunScope "cleanup-run/recovery-plane-fixture")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "000000000000") (AwsRegion "eu-west-2")))
    ReconcileDesiredAbsent

emptyRun :: RecoveryRepairRun
emptyRun =
  RecoveryRepairRun
    { recoveryRepairAttempted = []
    , recoveryRepairUnattempted = []
    }

establishWith
  :: Either Text LocalRke2RecoveryStateView
  -> RetainedArtifactStoreObservation
  -> (String -> Either Text ())
  -> IO (HostRecoveryPlaneEstablishment, [String])
establishWith state store answer = do
  calls <- newIORef []
  inventory <- requireInventory
  catalog <- requireCatalog
  recovery <- requireRecovery
  establishment <-
    establishHostRecoveryPlane
      inventory
      catalog
      recovery
      HostRecoveryPlaneRepair
        { hostRecoveryObserveState = pure state
        , hostRecoveryObserveStore = pure store
        , hostRecoveryRepairBoundary = recordingBoundary calls answer
        }
  issued <- readIORef calls
  pure (establishment, issued)

recordingBoundary
  :: IORef [String] -> (String -> Either Text ()) -> RecoveryRepairBoundary IO
recordingBoundary calls answer =
  RecoveryRepairBoundary
    { repairInstallSubstrate = \_ -> record "install"
    , repairStartSubstrateService = record "start"
    , repairAwaitSubstrateApi = record "await"
    , repairLoadRetainedImage = \_ -> record "image"
    , repairReconcileRecoveryChart = \_ -> record "chart"
    }
 where
  record name = do
    modifyIORef' calls (++ [name])
    pure (answer name)

alwaysOk :: String -> Either Text ()
alwaysOk _ = Right ()

failing :: String -> String -> Either Text ()
failing target name
  | name == target = Left "archive is truncated"
  | otherwise = Right ()

exactStore :: RetainedArtifactStoreObservation
exactStore =
  RetainedArtifactStoreMembers
    [ RetainedArtifactMember
        { retainedArtifactMemberRelativePath = pathFor kind
        , retainedArtifactMemberDigest = RetainedArtifactMemberDigested (digestFor kind)
        }
    | kind <- [minBound .. maxBound]
    ]

emptyStore :: RetainedArtifactStoreObservation
emptyStore = RetainedArtifactStoreMembers []

digestFor :: RetainedArtifactKind -> Text
digestFor kind = "sha256:" <> Text.replicate 64 (Text.singleton (digestSeed kind))

digestSeed :: RetainedArtifactKind -> Char
digestSeed kind = case kind of
  RetainedSubstrateInstaller -> '1'
  RetainedSubstrateReleaseTarball -> '6'
  RetainedSubstrateChecksum -> '7'
  RetainedSubstrateSystemImages -> '2'
  RetainedObjectStoreImage -> '3'
  RetainedSecretStoreImage -> '4'
  RetainedProdboxRuntimeImage -> '5'

pathFor :: RetainedArtifactKind -> FilePath
pathFor kind = "recovery-artifacts/amd64/" ++ retainedArtifactKindText kind ++ ".tar"

requireInventory :: IO RetainedArtifactInventory
requireInventory =
  case retainedArtifactInventory RetainedArtifactAmd64 (fmap entryFor [minBound .. maxBound]) of
    Left err ->
      expectationFailure (renderRetainedArtifactInventoryError err) >> fail "unreachable"
    Right inventory -> pure inventory
 where
  entryFor kind =
    RetainedArtifactEntry
      { retainedArtifactEntryKind = kind
      , retainedArtifactEntryArchitecture = RetainedArtifactAmd64
      , retainedArtifactEntryVersion = "0.0.0-fixture"
      , retainedArtifactEntryDigest = Text.unpack (digestFor kind)
      , retainedArtifactEntryRelativePath = pathFor kind
      }

requireCatalog :: IO RetainedArtifactSourceCatalog
requireCatalog =
  case retainedArtifactSourceCatalog RetainedArtifactAmd64 (fmap sourceFor [minBound .. maxBound]) of
    Left err ->
      expectationFailure (renderRetainedArtifactSourceError err) >> fail "unreachable"
    Right catalog -> pure catalog
 where
  sourceFor kind =
    RetainedArtifactSourceEntry
      { retainedArtifactSourceEntryKind = kind
      , retainedArtifactSourceEntryArchitecture = RetainedArtifactAmd64
      , retainedArtifactSourceEntryDigest = digestFor kind
      , retainedArtifactSourceEntryLocator =
          RetainedArtifactPinnedArchive
            ( "https://mirror.example.com/amd64/"
                <> Text.pack (retainedArtifactKindText kind)
                <> ".tar"
            )
      }

requireRecovery :: IO OrdinaryTeardownRecovery
requireRecovery =
  case ordinaryTeardownRecovery OrdinaryTeardownWithoutTargetAgent of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRecoveryError err) >> fail "unreachable"
    Right recovery -> pure recovery

isApplied :: HostRecoveryPlaneEstablishment -> Bool
isApplied establishment = case establishment of
  HostRecoveryPlaneRepairApplied _ -> True
  _ -> False

isStopped :: HostRecoveryPlaneEstablishment -> Bool
isStopped establishment = case establishment of
  HostRecoveryPlaneRepairStopped _ _ -> True
  _ -> False

isInadmissible :: HostRecoveryPlaneEstablishment -> Bool
isInadmissible establishment = case establishment of
  HostRecoveryPlaneRepairInadmissible _ -> True
  _ -> False

isUnobservableState :: HostRecoveryPlaneEstablishment -> Bool
isUnobservableState establishment = case establishment of
  HostRecoveryPlaneStateUnobservable _ -> True
  _ -> False

unattemptedOf :: HostRecoveryPlaneEstablishment -> Int
unattemptedOf establishment = case establishment of
  HostRecoveryPlaneRepairApplied run -> length (recoveryRepairUnattempted run)
  HostRecoveryPlaneRepairStopped run _ -> length (recoveryRepairUnattempted run)
  _ -> 0

isRefused :: HostCleanupEffectOutcome -> Bool
isRefused outcome = case outcome of
  HostCleanupEffectRefused _ -> True
  _ -> False
