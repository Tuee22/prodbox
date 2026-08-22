{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownRecoveryRepairExecution
  ( lifecycleTeardownRecoveryRepairExecutionSuite
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NonEmpty
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
  ( OrdinaryTeardownRepairError (..)
  , RetainedArtifactArchitecture (..)
  , RetainedArtifactEntry (..)
  , RetainedArtifactInventory
  , RetainedArtifactKind (..)
  , renderRetainedArtifactInventoryError
  , retainedArtifactInventory
  , retainedArtifactKindText
  , retainedArtifactRefKind
  )
import Prodbox.Lifecycle.Teardown.RecoveryRepairExecution
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactCustodyPlan
  , RetainedArtifactLocator (..)
  , RetainedArtifactMember (..)
  , RetainedArtifactMemberDigest (..)
  , RetainedArtifactSourceCatalog
  , RetainedArtifactSourceEntry (..)
  , RetainedArtifactStoreObservation (..)
  , planRetainedArtifactCustody
  , renderRetainedArtifactCustodyError
  , renderRetainedArtifactSourceError
  , retainedArtifactCustodyPlanAcquisitions
  , retainedArtifactCustodyPlanCollections
  , retainedArtifactCustodyPlanVerified
  , retainedArtifactSourceCatalog
  )
import TestSupport

lifecycleTeardownRecoveryRepairExecutionSuite :: SuiteBuilder ()
lifecycleTeardownRecoveryRepairExecutionSuite =
  describe "Sprint 4.86 recovery repair execution" $ do
    describe "admitting a rendered repair against an observed store" $ do
      it "admits every matrix arm when the store holds exactly the pinned bytes" $ do
        mapM_
          ( \state -> do
              repair <- requireAdmitted state (RetainedArtifactStoreMembers matchingMembers)
              admittedRecoveryRepairState repair `shouldBe` state
              admittedRecoveryRepairArchitecture repair `shouldBe` RetainedArtifactAmd64
          )
          [ LocalRke2RecoveryHealthy
          , LocalRke2RecoveryStopped
          , LocalRke2RecoveryAbsent
          ]

      it "admits the absent arm as install, start, await, image loads, then charts" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        take 3 (fmap stepShape (admittedRecoveryRepairSteps repair))
          `shouldBe` ["install", "start", "await"]
        filter (== "load") (fmap stepShape (admittedRecoveryRepairSteps repair))
          `shouldBe` ["load", "load", "load"]
        filter (== "chart") (fmap stepShape (admittedRecoveryRepairSteps repair))
          `shouldSatisfy` (not . null)

      it "admits the healthy arm with no substrate step at all" $ do
        repair <- requireAdmitted LocalRke2RecoveryHealthy (RetainedArtifactStoreMembers matchingMembers)
        filter (`elem` ["install", "start", "await"]) (fmap stepShape (admittedRecoveryRepairSteps repair))
          `shouldBe` []

      it "carries the store-relative path and the pinned digest the admission checked" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        let artifacts = admittedRecoveryRepairArtifacts repair
        mapM_
          ( \artifact -> do
              verifiedRetainedArtifactRelativePath artifact
                `shouldBe` pathFor (verifiedRetainedArtifactKind artifact)
              verifiedRetainedArtifactDigest artifact
                `shouldBe` digestFor (verifiedRetainedArtifactKind artifact)
          )
          artifacts
        artifacts `shouldSatisfy` (not . null)

      it "does not refuse a repair over a store member the plan does not read" $ do
        let polluted =
              RetainedArtifactStoreMembers
                ( matchingMembers
                    ++ [ RetainedArtifactMember
                           { retainedArtifactMemberRelativePath = "recovery-artifacts/amd64/stray.tar"
                           , retainedArtifactMemberDigest =
                               RetainedArtifactMemberDigested foreignDigest
                           }
                       ]
                )
        _ <- requireAdmitted LocalRke2RecoveryAbsent polluted
        -- The same observation is a custody obligation, which is where a stray
        -- member belongs: it is collected, rather than allowed to block a
        -- recovery it does not participate in.
        custody <- requireCustodyPlan polluted
        retainedArtifactCustodyPlanCollections custody
          `shouldBe` ["recovery-artifacts/amd64/stray.tar"]

    describe "refusing a repair the store cannot support" $ do
      it "refuses an empty store and names the acquisition that closes it" $ do
        admission <- requireAdmission LocalRke2RecoveryAbsent emptyInventoryObservation
        admission `shouldSatisfy` isUnreadyRefusal
        custody <- requireRemedy LocalRke2RecoveryAbsent emptyInventoryObservation
        fmap retainedArtifactRefKind (retainedArtifactCustodyPlanAcquisitions custody)
          `shouldBe` [minBound .. maxBound]
        retainedArtifactCustodyPlanVerified custody `shouldBe` []

      it "refuses a corrupt artifact and remedies it as a replacement" $ do
        let corrupted =
              RetainedArtifactStoreMembers
                ( memberFor RetainedSubstrateInstaller (RetainedArtifactMemberDigested foreignDigest)
                    : [ member
                      | member <- matchingMembers
                      , retainedArtifactMemberRelativePath member
                          /= pathFor RetainedSubstrateInstaller
                      ]
                )
        admission <- requireAdmission LocalRke2RecoveryAbsent corrupted
        admission `shouldSatisfy` isUnreadyRefusal
        custody <- requireRemedy LocalRke2RecoveryAbsent corrupted
        fmap retainedArtifactRefKind (retainedArtifactCustodyPlanAcquisitions custody)
          `shouldBe` [RetainedSubstrateInstaller]

      it "refuses an unobservable store with no remedy at all" $ do
        admission <-
          requireAdmission
            LocalRke2RecoveryAbsent
            (RetainedArtifactStoreUnobservable "listing failed")
        case admission of
          RecoveryRepairRefused (RecoveryRepairStoreUnobservable detail) remedy -> do
            detail `shouldBe` "listing failed"
            remedy `shouldSatisfy` isUnavailableRemedy
          other -> expectationFailure (show other)

      it "refuses an unrenderable plan with no remedy, because nothing pins the bytes" $ do
        recovery <- requireRecovery
        catalog <- requireCatalog
        inventory <- requirePartialInventory
        let admission =
              admitRecoveryRepair
                inventory
                catalog
                recovery
                LocalRke2RecoveryAbsent
                (RetainedArtifactStoreMembers [])
        case admission of
          RecoveryRepairRefused (RecoveryRepairUnrenderable err) remedy -> do
            err `shouldSatisfy` isUnretainedArtifacts
            remedy `shouldSatisfy` isUnavailableRemedy
          other -> expectationFailure (show other)

      it "renders every refusal as an operator-readable line" $ do
        admission <- requireAdmission LocalRke2RecoveryAbsent emptyInventoryObservation
        case admission of
          RecoveryRepairRefused refusal remedy -> do
            renderRecoveryRepairRefusal refusal
              `shouldSatisfy` (Text.isInfixOf "is not admitted" . Text.pack)
            renderRecoveryRepairRemedy remedy
              `shouldSatisfy` (Text.isInfixOf "custody" . Text.pack)
          other -> expectationFailure (show other)

    describe "applying an admitted repair" $ do
      it "runs every step in plan order and leaves no unattempted tail" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        (run, journal) <- runApply (honestBoundary) repair
        recoveryRepairUnattempted run `shouldBe` []
        recoveryRepairRunFailure run `shouldBe` Nothing
        fmap fst journal
          `shouldBe` fmap stepShape (admittedRecoveryRepairSteps repair)
        fmap (renderRecoveryRepairStepOutcome . snd) (recoveryRepairAttempted run)
          `shouldSatisfy` all (== "succeeded")

      it "stops at a failed install and never starts the service" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        (run, journal) <- runApply (failingBoundary "install" "archive is truncated") repair
        fmap fst journal `shouldBe` ["install"]
        length (recoveryRepairAttempted run) `shouldBe` 1
        recoveryRepairUnattempted run
          `shouldBe` drop 1 (admittedRecoveryRepairSteps repair)
        fmap (stepShape . fst) (recoveryRepairRunFailure run) `shouldBe` Just "install"
        fmap snd (recoveryRepairRunFailure run) `shouldBe` Just "archive is truncated"

      it "stops when the API never arrives and loads no image against it" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        (run, journal) <- runApply (failingBoundary "await" "api never became reachable") repair
        fmap fst journal `shouldBe` ["install", "start", "await"]
        fmap (stepShape . fst) (recoveryRepairRunFailure run) `shouldBe` Just "await"
        fmap stepShape (recoveryRepairUnattempted run)
          `shouldSatisfy` all (`elem` ["load", "chart"])

      it "stops at a failing chart with the substrate steps already attempted" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        (run, journal) <- runApply (failingBoundary "chart" "release failed") repair
        fmap (stepShape . fst) (recoveryRepairRunFailure run) `shouldBe` Just "chart"
        journal `shouldSatisfy` any ((== "await") . fst)
        fmap stepShape (recoveryRepairUnattempted run)
          `shouldSatisfy` all (== "chart")

      it "hands the boundary exactly the artifacts the admission verified" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        (_, journal) <- runApply honestBoundary repair
        [ detail
          | (label, detail) <- journal
          , label `elem` ["install", "load"]
          ]
          `shouldSatisfy` all (Text.isPrefixOf "recovery-artifacts/amd64/")

    describe "reading substrate convergence back" $ do
      it "converges only on a freshly observed healthy substrate" $ do
        recoveryRepairSubstrateReadBack (Right LocalRke2RecoveryHealthy)
          `shouldBe` RecoveryRepairSubstrateConverged
        recoveryRepairSubstrateReadBack (Right LocalRke2RecoveryStopped)
          `shouldBe` RecoveryRepairSubstrateUnconverged LocalRke2RecoveryStopped
        recoveryRepairSubstrateReadBack (Right LocalRke2RecoveryAbsent)
          `shouldBe` RecoveryRepairSubstrateUnconverged LocalRke2RecoveryAbsent

      it "closes nothing when the substrate cannot be observed" $ do
        recoveryRepairSubstrateReadBack (Left "systemd is unreachable")
          `shouldBe` RecoveryRepairSubstrateUnverifiable "systemd is unreachable"

      it "does not read convergence out of a run in which every step succeeded" $ do
        repair <- requireAdmitted LocalRke2RecoveryAbsent (RetainedArtifactStoreMembers matchingMembers)
        (run, _) <- runApply honestBoundary repair
        recoveryRepairRunFailure run `shouldBe` Nothing
        recoveryRepairSubstrateReadBack (Right LocalRke2RecoveryAbsent)
          `shouldBe` RecoveryRepairSubstrateUnconverged LocalRke2RecoveryAbsent

      it "renders each verdict as an operator-readable line" $ do
        mapM_
          ( \verdict ->
              renderRecoveryRepairSubstrateConvergence verdict
                `shouldSatisfy` (Text.isInfixOf "substrate" . Text.pack)
          )
          [ RecoveryRepairSubstrateConverged
          , RecoveryRepairSubstrateUnconverged LocalRke2RecoveryStopped
          , RecoveryRepairSubstrateUnverifiable "unreadable"
          ]

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

digestFor :: RetainedArtifactKind -> Text
digestFor kind = "sha256:" <> Text.replicate 64 (Text.singleton (digestSeed kind))

digestSeed :: RetainedArtifactKind -> Char
digestSeed = \case
  RetainedSubstrateInstaller -> '1'
  RetainedSubstrateReleaseTarball -> '6'
  RetainedSubstrateChecksum -> '7'
  RetainedSubstrateSystemImages -> '2'
  RetainedObjectStoreImage -> '3'
  RetainedSecretStoreImage -> '4'
  RetainedProdboxRuntimeImage -> '5'

foreignDigest :: Text
foreignDigest = "sha256:" <> Text.replicate 64 "e"

pathFor :: RetainedArtifactKind -> FilePath
pathFor kind = "recovery-artifacts/amd64/" ++ retainedArtifactKindText kind ++ ".tar"

entryFor :: RetainedArtifactKind -> RetainedArtifactEntry
entryFor kind =
  RetainedArtifactEntry
    { retainedArtifactEntryKind = kind
    , retainedArtifactEntryArchitecture = RetainedArtifactAmd64
    , retainedArtifactEntryVersion = "0.0.0-fixture"
    , retainedArtifactEntryDigest = Text.unpack (digestFor kind)
    , retainedArtifactEntryRelativePath = pathFor kind
    }

sourceFor :: RetainedArtifactKind -> RetainedArtifactSourceEntry
sourceFor kind =
  RetainedArtifactSourceEntry
    { retainedArtifactSourceEntryKind = kind
    , retainedArtifactSourceEntryArchitecture = RetainedArtifactAmd64
    , retainedArtifactSourceEntryDigest = digestFor kind
    , retainedArtifactSourceEntryLocator =
        RetainedArtifactPinnedArchive
          ("https://mirror.example.com/amd64/" <> Text.pack (retainedArtifactKindText kind) <> ".tar")
    }

memberFor :: RetainedArtifactKind -> RetainedArtifactMemberDigest -> RetainedArtifactMember
memberFor kind digest =
  RetainedArtifactMember
    { retainedArtifactMemberRelativePath = pathFor kind
    , retainedArtifactMemberDigest = digest
    }

matchingMembers :: [RetainedArtifactMember]
matchingMembers =
  [ memberFor kind (RetainedArtifactMemberDigested (digestFor kind))
  | kind <- [minBound .. maxBound]
  ]

emptyInventoryObservation :: RetainedArtifactStoreObservation
emptyInventoryObservation = RetainedArtifactStoreMembers []

-- ---------------------------------------------------------------------------
-- Fake boundaries
-- ---------------------------------------------------------------------------

-- | Records what each step was asked to do, so a test can prove a step did
-- /not/ run as well as that one did.
recordingBoundary
  :: IORef [(String, Text)]
  -> (String -> IO (Either Text ()))
  -> RecoveryRepairBoundary IO
recordingBoundary journal decide =
  RecoveryRepairBoundary
    { repairInstallSubstrate = \artifacts -> do
        record "install" (relativePaths (NonEmpty.toList artifacts))
        decide "install"
    , repairStartSubstrateService = do
        record "start" ""
        decide "start"
    , repairAwaitSubstrateApi = do
        record "await" ""
        decide "await"
    , repairLoadRetainedImage = \artifact -> do
        record "load" (Text.pack (verifiedRetainedArtifactRelativePath artifact))
        decide "load"
    , repairReconcileRecoveryChart = \chart -> do
        record "chart" (Text.pack chart)
        decide "chart"
    }
 where
  record label detail = modifyIORef' journal (++ [(label, detail)])
  relativePaths artifacts =
    Text.pack
      ( case artifacts of
          [] -> ""
          artifact : _ -> verifiedRetainedArtifactRelativePath artifact
      )

honestBoundary :: IORef [(String, Text)] -> RecoveryRepairBoundary IO
honestBoundary journal = recordingBoundary journal (const (pure (Right ())))

failingBoundary
  :: String -> Text -> IORef [(String, Text)] -> RecoveryRepairBoundary IO
failingBoundary failing detail journal =
  recordingBoundary
    journal
    (\shape -> pure (if shape == failing then Left detail else Right ()))

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

stepShape :: AdmittedRepairStep -> String
stepShape = \case
  AdmittedInstallSubstrateFromRetained _ -> "install"
  AdmittedStartSubstrateService -> "start"
  AdmittedAwaitSubstrateApi -> "await"
  AdmittedLoadRetainedImage _ -> "load"
  AdmittedReconcileRecoveryChart _ -> "chart"

runApply
  :: (IORef [(String, Text)] -> RecoveryRepairBoundary IO)
  -> AdmittedRecoveryRepair
  -> IO (RecoveryRepairRun, [(String, Text)])
runApply boundary repair = do
  journal <- newIORef []
  run <- applyRecoveryRepair (boundary journal) repair
  effects <- readIORef journal
  pure (run, effects)

isUnreadyRefusal :: RecoveryRepairAdmission -> Bool
isUnreadyRefusal = \case
  RecoveryRepairRefused (RecoveryRepairArtifactsUnready _) _ -> True
  _ -> False

isUnavailableRemedy :: RecoveryRepairRemedy -> Bool
isUnavailableRemedy = \case
  RecoveryRepairRemedyUnavailable _ -> True
  _ -> False

isUnretainedArtifacts :: OrdinaryTeardownRepairError -> Bool
isUnretainedArtifacts = \case
  OrdinaryTeardownRepairUnretainedArtifacts {} -> True
  _ -> False

requireRecovery :: IO OrdinaryTeardownRecovery
requireRecovery =
  case ordinaryTeardownRecovery OrdinaryTeardownWithoutTargetAgent of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRecoveryError err) >> fail "unreachable"
    Right recovery -> pure recovery

requireInventory :: IO RetainedArtifactInventory
requireInventory = buildInventory (fmap entryFor [minBound .. maxBound])

-- | An inventory that retains everything except the substrate installer, so an
-- absent substrate needs bytes nothing pins.
requirePartialInventory :: IO RetainedArtifactInventory
requirePartialInventory =
  buildInventory
    [entryFor kind | kind <- [minBound .. maxBound], kind /= RetainedSubstrateInstaller]

buildInventory :: [RetainedArtifactEntry] -> IO RetainedArtifactInventory
buildInventory entries =
  case retainedArtifactInventory RetainedArtifactAmd64 entries of
    Left err ->
      expectationFailure (renderRetainedArtifactInventoryError err) >> fail "unreachable"
    Right inventory -> pure inventory

requireCatalog :: IO RetainedArtifactSourceCatalog
requireCatalog =
  case retainedArtifactSourceCatalog RetainedArtifactAmd64 (fmap sourceFor [minBound .. maxBound]) of
    Left err ->
      expectationFailure (renderRetainedArtifactSourceError err) >> fail "unreachable"
    Right catalog -> pure catalog

requireAdmission
  :: LocalRke2RecoveryStateView
  -> RetainedArtifactStoreObservation
  -> IO RecoveryRepairAdmission
requireAdmission state observation = do
  inventory <- requireInventory
  catalog <- requireCatalog
  recovery <- requireRecovery
  pure (admitRecoveryRepair inventory catalog recovery state observation)

requireAdmitted
  :: LocalRke2RecoveryStateView
  -> RetainedArtifactStoreObservation
  -> IO AdmittedRecoveryRepair
requireAdmitted state observation = do
  admission <- requireAdmission state observation
  case admission of
    RecoveryRepairAdmitted repair -> pure repair
    RecoveryRepairRefused refusal _ ->
      expectationFailure (renderRecoveryRepairRefusal refusal) >> fail "unreachable"

requireCustodyPlan
  :: RetainedArtifactStoreObservation -> IO RetainedArtifactCustodyPlan
requireCustodyPlan observation = do
  inventory <- requireInventory
  catalog <- requireCatalog
  case planRetainedArtifactCustody inventory catalog observation of
    Left err ->
      expectationFailure (renderRetainedArtifactCustodyError err) >> fail "unreachable"
    Right custody -> pure custody

requireRemedy
  :: LocalRke2RecoveryStateView
  -> RetainedArtifactStoreObservation
  -> IO RetainedArtifactCustodyPlan
requireRemedy state observation = do
  admission <- requireAdmission state observation
  case admission of
    RecoveryRepairRefused _ (RecoveryRepairRemedyCustody custody) -> pure custody
    other -> expectationFailure (show other) >> fail "unreachable"
