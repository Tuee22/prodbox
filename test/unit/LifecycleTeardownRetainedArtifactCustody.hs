{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownRetainedArtifactCustody
  ( lifecycleTeardownRetainedArtifactCustodySuite
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.LocalRke2RecoveryState (LocalRke2RecoveryStateView (..))
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (OrdinaryTeardownWithoutTargetAgent)
  , ordinaryTeardownRecovery
  , renderOrdinaryTeardownRecoveryError
  )
import Prodbox.Config.OrdinaryTeardownRepair
  ( OrdinaryTeardownRepairPlan
  , RetainedArtifactArchitecture (..)
  , RetainedArtifactEntry (..)
  , RetainedArtifactInventory
  , RetainedArtifactKind (..)
  , RetainedArtifactRef
  , lookupRetainedArtifact
  , ordinaryTeardownRepairPlan
  , renderOrdinaryTeardownRepairError
  , renderRetainedArtifactInventoryError
  , retainedArtifactInventory
  , retainedArtifactKindText
  , retainedArtifactRefRelativePath
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
import TestSupport

lifecycleTeardownRetainedArtifactCustodySuite :: SuiteBuilder ()
lifecycleTeardownRetainedArtifactCustodySuite =
  describe "Sprint 4.86 retained artifact custody" $ do
    describe "pinned source catalog" $ do
      it "accepts one pinned https archive per kind" $ do
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        retainedArtifactSourceCatalogKinds catalog `shouldBe` [minBound .. maxBound]
        fmap retainedArtifactSourceDigest (lookupRetainedArtifactSource RetainedSubstrateInstaller catalog)
          `shouldBe` Just (digestFor RetainedSubstrateInstaller)

      it "refuses a second source for one kind" $ do
        retainedArtifactSourceCatalog
          RetainedArtifactAmd64
          (sourceFor RetainedSubstrateInstaller : completeSources)
          `shouldBe` Left
            (RetainedArtifactSourceDuplicateKind RetainedSubstrateInstaller)

      it "refuses a source declaring another architecture" $ do
        let foreign_ =
              (sourceFor RetainedObjectStoreImage)
                { retainedArtifactSourceEntryArchitecture = RetainedArtifactArm64
                }
        retainedArtifactSourceCatalog RetainedArtifactAmd64 [foreign_]
          `shouldBe` Left
            ( RetainedArtifactSourceForeignArchitecture
                RetainedObjectStoreImage
                RetainedArtifactAmd64
                RetainedArtifactArm64
            )

      it "refuses a non-canonical digest" $ do
        let uppercase =
              (sourceFor RetainedObjectStoreImage)
                { retainedArtifactSourceEntryDigest = "sha256:" <> Text.replicate 64 "A"
                }
        retainedArtifactSourceCatalog RetainedArtifactAmd64 [uppercase]
          `shouldBe` Left
            ( RetainedArtifactSourceMalformedDigest
                RetainedObjectStoreImage
                ("sha256:" <> Text.replicate 64 "A")
            )

      it "refuses every locator shape that is not an immutable https archive" $ do
        let refusalFor locator =
              retainedArtifactSourceCatalog
                RetainedArtifactAmd64
                [ (sourceFor RetainedObjectStoreImage)
                    { retainedArtifactSourceEntryLocator = RetainedArtifactPinnedArchive locator
                    }
                ]
        mapM_
          (\locator -> refusalFor locator `shouldSatisfy` isSourceRefusal)
          [ "http://mirror.example.com/artifact.tar"
          , "https://operator:secret@mirror.example.com/artifact.tar"
          , "https://mirror.example.com/../artifact.tar"
          , "https://mirror.example.com/artifact .tar"
          ]
        refusalFor "https://mirror.example.com/artifact.tar"
          `shouldSatisfy` isRight

    describe "planning custody against an observed store" $ do
      it "acquires everything an empty store does not hold" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers [])
        fmap kindOf (retainedArtifactCustodyPlanAcquisitions plan)
          `shouldBe` [minBound .. maxBound]
        retainedArtifactCustodyPlanCollections plan `shouldBe` []
        retainedArtifactCustodyPlanVerified plan `shouldBe` []

      it "verifies a store that already holds exactly the pinned bytes" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers matchingMembers)
        fmap kindOf (retainedArtifactCustodyPlanVerified plan)
          `shouldBe` [minBound .. maxBound]
        retainedArtifactCustodyPlanAcquisitions plan `shouldBe` []
        retainedArtifactCustodyPlanCollections plan `shouldBe` []

      it "replaces a mismatched member and an unreadable one, preserving which is which" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        let members =
              [ memberFor RetainedSubstrateInstaller (RetainedArtifactMemberDigested foreignDigest)
              , memberFor RetainedObjectStoreImage (RetainedArtifactMemberUnreadable "permission denied")
              ]
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers members)
        [ (kindOf ref, reason)
          | RetainedArtifactReplace ref _ reason <- retainedArtifactCustodyPlanActions plan
          ]
          `shouldBe` [ (RetainedSubstrateInstaller, RetainedArtifactDigestMismatch foreignDigest)
                     , (RetainedObjectStoreImage, RetainedArtifactDigestUnreadable "permission denied")
                     ]

      it "collects every member the inventory does not name, and only those" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        let strays =
              [ RetainedArtifactMember
                  "recovery-artifacts/amd64/superseded.tar"
                  (RetainedArtifactMemberDigested foreignDigest)
              , RetainedArtifactMember
                  "recovery-artifacts/arm64/substrate_installer.tar"
                  (RetainedArtifactMemberDigested foreignDigest)
              ]
        plan <-
          requirePlan
            inventory
            catalog
            (RetainedArtifactStoreMembers (matchingMembers ++ strays))
        retainedArtifactCustodyPlanCollections plan
          `shouldBe` [ "recovery-artifacts/amd64/superseded.tar"
                     , "recovery-artifacts/arm64/substrate_installer.tar"
                     ]
        -- The two-sided property: no collection names a retained location, and
        -- every retained location survives the collection set.
        inventoryPaths <- retainedPaths inventory
        mapM_
          (\path -> retainedArtifactCustodyPlanCollections plan `shouldNotContain` [path])
          inventoryPaths

      it "classifies every inventory entry and every observed member exactly once" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        let stray =
              RetainedArtifactMember
                "recovery-artifacts/amd64/superseded.tar"
                (RetainedArtifactMemberDigested foreignDigest)
            members = take 2 matchingMembers ++ [stray]
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers members)
        length (retainedArtifactCustodyPlanActions plan)
          `shouldBe` (length [minBound .. maxBound :: RetainedArtifactKind] + 1)
        length (retainedArtifactCustodyPlanVerified plan) `shouldBe` 2
        length (retainedArtifactCustodyPlanAcquisitions plan)
          `shouldBe` (length [minBound .. maxBound :: RetainedArtifactKind] - 2)

      it "plans nothing at all against an unobservable store" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        planRetainedArtifactCustody
          inventory
          catalog
          (RetainedArtifactStoreUnobservable "listing failed")
          `shouldBe` Left (RetainedArtifactCustodyStoreUnobservable "listing failed")

      it "reports the complete unsourced set rather than the first hole" $ do
        inventory <- requireInventory
        catalog <-
          requireCatalog
            RetainedArtifactAmd64
            [ source
            | source <- completeSources
            , retainedArtifactSourceEntryKind source == RetainedObjectStoreImage
            ]
        case planRetainedArtifactCustody inventory catalog (RetainedArtifactStoreMembers []) of
          Left (RetainedArtifactCustodyUnsourced architecture missing) -> do
            architecture `shouldBe` RetainedArtifactAmd64
            NonEmpty.toList missing
              `shouldBe` [ kind
                         | kind <- [minBound .. maxBound]
                         , kind /= RetainedObjectStoreImage
                         ]
          other -> expectationFailure ("expected an unsourced refusal, got " ++ show other)

      it "refuses a source whose digest is not the digest the inventory pinned" $ do
        inventory <- requireInventory
        catalog <-
          requireCatalog
            RetainedArtifactAmd64
            ( (sourceFor RetainedSecretStoreImage) {retainedArtifactSourceEntryDigest = foreignDigest}
                : [ source
                  | source <- completeSources
                  , retainedArtifactSourceEntryKind source /= RetainedSecretStoreImage
                  ]
            )
        planRetainedArtifactCustody inventory catalog (RetainedArtifactStoreMembers [])
          `shouldBe` Left
            ( RetainedArtifactCustodySourceDigestMismatch
                RetainedSecretStoreImage
                (digestFor RetainedSecretStoreImage)
                foreignDigest
            )

      it "refuses a catalog rendered for another architecture" $ do
        inventory <- requireInventory
        catalog <-
          requireCatalog
            RetainedArtifactArm64
            [ source {retainedArtifactSourceEntryArchitecture = RetainedArtifactArm64}
            | source <- completeSources
            ]
        planRetainedArtifactCustody inventory catalog (RetainedArtifactStoreMembers [])
          `shouldBe` Left
            ( RetainedArtifactCustodyArchitectureMismatch
                RetainedArtifactAmd64
                RetainedArtifactArm64
            )

    describe "applying a custody plan through its boundary" $ do
      it "places delivered bytes that match the pinned digest and issues no effect for a verified member" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <-
          requirePlan
            inventory
            catalog
            (RetainedArtifactStoreMembers (take 1 matchingMembers))
        (steps, effects) <- runApply honestBoundary plan
        outcomes steps
          `shouldContain` [RetainedArtifactCustodyAlreadyRetained]
        [ outcome
          | outcome@(RetainedArtifactCustodyRetained _) <- outcomes steps
          ]
          `shouldBe` [ RetainedArtifactCustodyRetained (digestFor kind)
                     | kind <- [minBound .. maxBound]
                     , kind /= RetainedSubstrateInstaller
                     ]
        length [effect | effect@("place", _) <- effects] `shouldBe` 4
        length [effect | effect@("discard", _) <- effects] `shouldBe` 0

      it "discards a delivery whose bytes are not the pinned ones instead of placing it" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers [])
        (steps, effects) <- runApply (dishonestBoundary foreignDigest) plan
        outcomes steps
          `shouldBe` [ RetainedArtifactCustodyDeliveryRejected (digestFor kind) foreignDigest
                     | kind <- [minBound .. maxBound]
                     ]
        [effect | effect@("place", _) <- effects] `shouldBe` []
        length [effect | effect@("discard", _) <- effects] `shouldBe` 5

      it "keeps a lost delivery, a failed placement, and a failed collection distinct" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <-
          requirePlan
            inventory
            catalog
            ( RetainedArtifactStoreMembers
                [ RetainedArtifactMember
                    "recovery-artifacts/amd64/superseded.tar"
                    (RetainedArtifactMemberDigested foreignDigest)
                ]
            )
        (lost, _) <- runApply (unreachableBoundary "connection reset") plan
        outcomes lost
          `shouldContain` [RetainedArtifactCustodyDeliveryLost "connection reset"]
        (unplaceable, _) <- runApply (unplaceableBoundary "read-only filesystem") plan
        outcomes unplaceable
          `shouldContain` [RetainedArtifactCustodyPlacementFailed "read-only filesystem"]
        (uncollectable, _) <- runApply (uncollectableBoundary "device busy") plan
        outcomes uncollectable
          `shouldContain` [RetainedArtifactCustodyCollectionFailed "device busy"]

      it "applies every remaining obligation after one of them fails" $ do
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers [])
        (steps, _) <- runApply (firstDeliveryLostBoundary "connection reset") plan
        length steps `shouldBe` length [minBound .. maxBound :: RetainedArtifactKind]
        take 1 (outcomes steps)
          `shouldBe` [RetainedArtifactCustodyDeliveryLost "connection reset"]
        drop 1 (outcomes steps)
          `shouldBe` [ RetainedArtifactCustodyRetained (digestFor kind)
                     | kind <- drop 1 [minBound .. maxBound]
                     ]

    describe "reading custody back" $ do
      it "converges only on the exact inventory member set" $ do
        inventory <- requireInventory
        retainedArtifactCustodyReadBack inventory (RetainedArtifactStoreMembers matchingMembers)
          `shouldBe` RetainedArtifactCustodyConverged

      it "reports a missing, a corrupt, and an unreferenced member together" $ do
        inventory <- requireInventory
        let members =
              [ memberFor RetainedSubstrateInstaller (RetainedArtifactMemberDigested foreignDigest)
              ]
                ++ drop 2 matchingMembers
                ++ [ RetainedArtifactMember
                       "recovery-artifacts/amd64/superseded.tar"
                       (RetainedArtifactMemberDigested foreignDigest)
                   ]
        case retainedArtifactCustodyReadBack inventory (RetainedArtifactStoreMembers members) of
          RetainedArtifactCustodyDiverged residue -> do
            NonEmpty.toList residue
              `shouldContain` [ RetainedArtifactCorrupt
                                  RetainedSubstrateInstaller
                                  (pathFor RetainedSubstrateInstaller)
                                  (RetainedArtifactDigestMismatch foreignDigest)
                              ]
            NonEmpty.toList residue
              `shouldContain` [ RetainedArtifactMissing
                                  RetainedSubstrateSystemImages
                                  (pathFor RetainedSubstrateSystemImages)
                              ]
            NonEmpty.toList residue
              `shouldContain` [RetainedArtifactUnreferenced "recovery-artifacts/amd64/superseded.tar"]
          other -> expectationFailure ("expected divergence, got " ++ show other)

      it "closes nothing when the store cannot be listed" $ do
        inventory <- requireInventory
        retainedArtifactCustodyReadBack inventory (RetainedArtifactStoreUnobservable "listing failed")
          `shouldBe` RetainedArtifactCustodyUnverifiable "listing failed"

      it "does not accept a successful delivery response as evidence of retention" $ do
        -- Every acquisition reports success and the store still holds nothing.
        -- Convergence is decided from the re-observation alone, so the run is
        -- divergent rather than complete.
        inventory <- requireInventory
        catalog <- requireCatalog RetainedArtifactAmd64 completeSources
        plan <- requirePlan inventory catalog (RetainedArtifactStoreMembers [])
        (steps, _) <- runApply honestBoundary plan
        outcomes steps
          `shouldBe` [ RetainedArtifactCustodyRetained (digestFor kind)
                     | kind <- [minBound .. maxBound]
                     ]
        retainedArtifactCustodyReadBack inventory (RetainedArtifactStoreMembers [])
          `shouldSatisfy` isDiverged

    describe "checking a rendered repair against the store" $ do
      it "names exactly the artifacts the plan's own steps read" $ do
        plan <- requireRepairPlan LocalRke2RecoveryAbsent
        fmap kindOf (retainedArtifactRepairPlanRefs plan)
          `shouldBe` [ RetainedSubstrateInstaller
                     , RetainedSubstrateSystemImages
                     , RetainedObjectStoreImage
                     , RetainedSecretStoreImage
                     , RetainedProdboxRuntimeImage
                     ]
        healthy <- requireRepairPlan LocalRke2RecoveryHealthy
        fmap kindOf (retainedArtifactRepairPlanRefs healthy)
          `shouldBe` [ RetainedObjectStoreImage
                     , RetainedSecretStoreImage
                     , RetainedProdboxRuntimeImage
                     ]

      it "is ready only when every named artifact is present and matching" $ do
        plan <- requireRepairPlan LocalRke2RecoveryAbsent
        retainedArtifactRepairReadiness plan (RetainedArtifactStoreMembers matchingMembers)
          `shouldBe` RetainedArtifactRepairReady

      it "refuses a validated plan whose declared bytes are not on disk" $ do
        -- The defect this closes: an inventory entry is a declaration, and a
        -- plan rendered from it alone can name an installer nothing retained.
        plan <- requireRepairPlan LocalRke2RecoveryAbsent
        case retainedArtifactRepairReadiness plan (RetainedArtifactStoreMembers []) of
          RetainedArtifactRepairUnready residue ->
            NonEmpty.toList residue
              `shouldBe` [ RetainedArtifactMissing kind (pathFor kind)
                         | kind <- [minBound .. maxBound]
                         ]
          other -> expectationFailure ("expected an unready repair, got " ++ show other)

      it "refuses a named artifact whose retained bytes do not match" $ do
        plan <- requireRepairPlan LocalRke2RecoveryHealthy
        let corrupted =
              memberFor RetainedSecretStoreImage (RetainedArtifactMemberDigested foreignDigest)
                : [ member
                  | member <- matchingMembers
                  , retainedArtifactMemberRelativePath member /= pathFor RetainedSecretStoreImage
                  ]
        case retainedArtifactRepairReadiness plan (RetainedArtifactStoreMembers corrupted) of
          RetainedArtifactRepairUnready residue ->
            NonEmpty.toList residue
              `shouldBe` [ RetainedArtifactCorrupt
                             RetainedSecretStoreImage
                             (pathFor RetainedSecretStoreImage)
                             (RetainedArtifactDigestMismatch foreignDigest)
                         ]
          other -> expectationFailure ("expected an unready repair, got " ++ show other)

      it "does not let a member the repair never reads block it" $ do
        plan <- requireRepairPlan LocalRke2RecoveryHealthy
        let stray =
              RetainedArtifactMember
                "recovery-artifacts/amd64/superseded.tar"
                (RetainedArtifactMemberDigested foreignDigest)
        retainedArtifactRepairReadiness
          plan
          (RetainedArtifactStoreMembers (matchingMembers ++ [stray]))
          `shouldBe` RetainedArtifactRepairReady

      it "does not start a repair against an unread store" $ do
        plan <- requireRepairPlan LocalRke2RecoveryAbsent
        retainedArtifactRepairReadiness plan (RetainedArtifactStoreUnobservable "listing failed")
          `shouldBe` RetainedArtifactRepairUnverifiable "listing failed"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- Digests are repeated nibbles: unmistakably synthetic, and distinct per kind
-- so a plan that confused two entries would not pass.
digestFor :: RetainedArtifactKind -> Text
digestFor kind = "sha256:" <> Text.replicate 64 (Text.singleton (digestNibble kind))

digestNibble :: RetainedArtifactKind -> Char
digestNibble kind = case kind of
  RetainedSubstrateInstaller -> '1'
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

completeSources :: [RetainedArtifactSourceEntry]
completeSources = fmap sourceFor [minBound .. maxBound]

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

-- ---------------------------------------------------------------------------
-- Fake boundaries
-- ---------------------------------------------------------------------------

-- | A boundary that records what it was asked to do, so a test can prove an
-- effect did /not/ happen as well as that one did.
recordingBoundary
  :: IORef [(String, Text)]
  -> (RetainedArtifactRef -> IO (Either Text RetainedArtifactStaging))
  -> (RetainedArtifactRef -> IO (Either Text ()))
  -> (FilePath -> IO (Either Text ()))
  -> RetainedArtifactCustodyBoundary IO
recordingBoundary journal acquire place remove =
  RetainedArtifactCustodyBoundary
    { custodyObserveStore = pure (RetainedArtifactStoreMembers [])
    , custodyAcquire = \ref _source -> do
        record "acquire" (Text.pack (retainedArtifactRefRelativePath ref))
        acquire ref
    , custodyPlace = \ref _staging -> do
        record "place" (Text.pack (retainedArtifactRefRelativePath ref))
        place ref
    , custodyDiscardStaging = \staging ->
        record "discard" (Text.pack (retainedArtifactStagingPath staging))
    , custodyRemoveMember = \relativePath -> do
        record "remove" (Text.pack relativePath)
        remove relativePath
    }
 where
  record label detail = modifyIORef' journal (++ [(label, detail)])

stagingFor :: RetainedArtifactRef -> Text -> RetainedArtifactStaging
stagingFor ref digest =
  RetainedArtifactStaging
    { retainedArtifactStagingPath =
        "artifacts.staging/" ++ retainedArtifactRefRelativePath ref
    , retainedArtifactStagingDigest = digest
    }

-- | Delivers exactly the bytes the inventory pinned.
honestBoundary :: IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO
honestBoundary journal =
  recordingBoundary
    journal
    (\ref -> pure (Right (stagingFor ref (pinnedFor ref))))
    (const (pure (Right ())))
    (const (pure (Right ())))

-- | Delivers bytes that hash to something else.
dishonestBoundary
  :: Text -> IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO
dishonestBoundary delivered journal =
  recordingBoundary
    journal
    (\ref -> pure (Right (stagingFor ref delivered)))
    (const (pure (Right ())))
    (const (pure (Right ())))

unreachableBoundary
  :: Text -> IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO
unreachableBoundary detail journal =
  recordingBoundary
    journal
    (const (pure (Left detail)))
    (const (pure (Right ())))
    (const (pure (Right ())))

unplaceableBoundary
  :: Text -> IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO
unplaceableBoundary detail journal =
  recordingBoundary
    journal
    (\ref -> pure (Right (stagingFor ref (pinnedFor ref))))
    (const (pure (Left detail)))
    (const (pure (Right ())))

uncollectableBoundary
  :: Text -> IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO
uncollectableBoundary detail journal =
  recordingBoundary
    journal
    (\ref -> pure (Right (stagingFor ref (pinnedFor ref))))
    (const (pure (Right ())))
    (const (pure (Left detail)))

-- | Loses only the first delivery, so the traversal's behaviour after a
-- failure is observable.
firstDeliveryLostBoundary
  :: Text -> IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO
firstDeliveryLostBoundary detail journal =
  recordingBoundary
    journal
    ( \ref ->
        if retainedArtifactRefRelativePath ref == pathFor minBound
          then pure (Left detail)
          else pure (Right (stagingFor ref (pinnedFor ref)))
    )
    (const (pure (Right ())))
    (const (pure (Right ())))

-- | The pinned digest a plan carries for a reference, recovered from the same
-- fixture table the inventory was built from.
pinnedFor :: RetainedArtifactRef -> Text
pinnedFor ref =
  case [kind | kind <- [minBound .. maxBound], pathFor kind == retainedArtifactRefRelativePath ref] of
    kind : _ -> digestFor kind
    [] -> foreignDigest

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

runApply
  :: (IORef [(String, Text)] -> RetainedArtifactCustodyBoundary IO)
  -> RetainedArtifactCustodyPlan
  -> IO ([RetainedArtifactCustodyStep], [(String, Text)])
runApply boundary plan = do
  journal <- newIORef []
  steps <- applyRetainedArtifactCustody (boundary journal) plan
  effects <- readIORef journal
  pure (steps, effects)

outcomes :: [RetainedArtifactCustodyStep] -> [RetainedArtifactCustodyOutcome]
outcomes = fmap retainedArtifactCustodyStepOutcome

kindOf :: RetainedArtifactRef -> RetainedArtifactKind
kindOf ref =
  case [kind | kind <- [minBound .. maxBound], pathFor kind == retainedArtifactRefRelativePath ref] of
    kind : _ -> kind
    [] -> RetainedProdboxRuntimeImage

retainedPaths :: RetainedArtifactInventory -> IO [FilePath]
retainedPaths inventory =
  pure
    [ retainedArtifactRefRelativePath ref
    | kind <- [minBound .. maxBound]
    , Just ref <- [lookupRetainedArtifact kind inventory]
    ]

isRight :: Either error value -> Bool
isRight = either (const False) (const True)

isSourceRefusal
  :: Either RetainedArtifactSourceError RetainedArtifactSourceCatalog -> Bool
isSourceRefusal = \case
  Left RetainedArtifactSourceMalformedLocator {} -> True
  _ -> False

isDiverged :: RetainedArtifactCustodyConvergence -> Bool
isDiverged = \case
  RetainedArtifactCustodyDiverged _ -> True
  _ -> False

requireInventory :: IO RetainedArtifactInventory
requireInventory =
  case retainedArtifactInventory RetainedArtifactAmd64 (fmap entryFor [minBound .. maxBound]) of
    Left err ->
      expectationFailure (renderRetainedArtifactInventoryError err) >> fail "unreachable"
    Right inventory -> pure inventory

requireCatalog
  :: RetainedArtifactArchitecture
  -> [RetainedArtifactSourceEntry]
  -> IO RetainedArtifactSourceCatalog
requireCatalog architecture entries =
  case retainedArtifactSourceCatalog architecture entries of
    Left err ->
      expectationFailure (renderRetainedArtifactSourceError err) >> fail "unreachable"
    Right catalog -> pure catalog

requireRepairPlan :: LocalRke2RecoveryStateView -> IO OrdinaryTeardownRepairPlan
requireRepairPlan state = do
  inventory <- requireInventory
  recovery <- case ordinaryTeardownRecovery OrdinaryTeardownWithoutTargetAgent of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRecoveryError err) >> fail "unreachable"
    Right recovery -> pure recovery
  case ordinaryTeardownRepairPlan inventory recovery state of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRepairError err) >> fail "unreachable"
    Right plan -> pure plan

requirePlan
  :: RetainedArtifactInventory
  -> RetainedArtifactSourceCatalog
  -> RetainedArtifactStoreObservation
  -> IO RetainedArtifactCustodyPlan
requirePlan inventory catalog observation =
  case planRetainedArtifactCustody inventory catalog observation of
    Left err ->
      expectationFailure (renderRetainedArtifactCustodyError err) >> fail "unreachable"
    Right plan -> pure plan
