{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownOwnershipManifest
  ( lifecycleTeardownOwnershipManifestSuite
  )
where

import Control.Monad (filterM)
import Data.ByteString qualified as ByteString
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Registry
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownOwnershipManifestSuite :: SuiteBuilder ()
lifecycleTeardownOwnershipManifestSuite =
  describe "ownership-manifest capability boundary" $ do
    it "keeps write-ahead data canonical and secret-free without minting authority" $ do
      let intent =
            mustRight
              (mkWriteAheadManifestIntent CascadeSurface AwsTestKey creationScope)
          write = initialWriteAheadManifestWrite intent
          durable = mustRight (captureDurableWriteAheadOwnershipManifest write)
          bytes = durableWriteAheadOwnershipManifestBytes durable
      ownershipManifestWriteStackKey write `shouldBe` AwsTestKey
      ownershipManifestWriteScope write `shouldBe` creationScope
      durableWriteAheadOwnershipManifestStackKey durable `shouldBe` AwsTestKey
      durableWriteAheadOwnershipManifestScope durable `shouldBe` creationScope
      ByteString.null bytes `shouldBe` False
      ByteString.length bytes
        `shouldSatisfy` (<= maximumDurableWriteAheadOwnershipManifestBytes)

    -- Sprint 4.85: the ownership relation is derived from two registry
    -- coordinates instead of authored beside them. It was authored, and it was
    -- wrong: `aws-test` was named the owner of a family whose coordinate is
    -- keyed on the EKS cluster's ownership tag, and `pulumi/aws-test/Main.yaml`
    -- declares no cluster at all.
    it "Sprint 4.85 derives controller ownership from the registry coordinates" $ do
      map
        (\edge -> (ownershipEdgeStackKey edge, ownershipEdgeResourceKey edge))
        registeredOwnershipEdges
        `shouldBe` [(AwsEksKey, AwsEbsPerRunTestKey)]

      -- The join is by cluster name, not by position or by which stack happens
      -- to be listed first: `aws-test` yields a candidate cluster name too, and
      -- the family names the EKS one.
      controllerOwnedFamilies
        `shouldBe` [(AwsEbsPerRunTestKey, "aws-eks-test-cluster")]
      lookup AwsEksKey registeredStackClusters `shouldBe` Just "aws-eks-test-cluster"
      lookup AwsTestKey registeredStackClusters `shouldBe` Just "aws-test-cluster"

      -- Every controller-owned family has an owning registered stack.
      controllerOwnedFamiliesWithoutRegisteredStack `shouldBe` []

      -- The observable behaviour change: the EKS stack's write-ahead manifest
      -- may now record the volumes its own cluster created, and the `aws-test`
      -- manifest may no longer adopt volumes that stack never creates.
      projectRegisteredOwnershipEdge AwsEksKey AwsEbsPerRunTestKey
        `shouldSatisfy` isRightEdge
      projectRegisteredOwnershipEdge AwsTestKey AwsEbsPerRunTestKey
        `shouldBe` Left (OwnershipEdgeNotRegistered AwsTestKey AwsEbsPerRunTestKey)

      -- And the EKS manifest is seeded with it, which is the recovery evidence
      -- the manifest exists to carry when both checkpoint copies are unusable.
      let eksIntent =
            mustRight
              (mkWriteAheadManifestIntent CascadeSurface AwsEksKey creationScope)
          eksEntries =
            map
              ownershipManifestEntryKey
              (ownershipManifestWriteEntries (initialWriteAheadManifestWrite eksIntent))
      sort eksEntries `shouldBe` sort [AwsEksKey, AwsEbsPerRunTestKey]

    it "Sprint 4.85 distinguishes an owning cluster from a merely sharing one" $ do
      -- `owned` makes the named cluster the owner; `shared` does not, because a
      -- shared resource outlives the cluster by design and has no controller
      -- owner to order a teardown against.
      coordinateControllerOwnerCluster
        ( AwsEbsPerRunFamilyCoordinate
            "prodbox.io/lifecycle"
            "per-run-test"
            "kubernetes.io/cluster/aws-eks-test-cluster"
            "owned"
        )
        `shouldBe` Just "aws-eks-test-cluster"
      coordinateControllerOwnerCluster
        ( AwsEbsPerRunFamilyCoordinate
            "prodbox.io/lifecycle"
            "per-run-test"
            "kubernetes.io/cluster/aws-eks-test-cluster"
            "shared"
        )
        `shouldBe` Nothing
      -- A retained family carries no cluster ownership tag at all, which is
      -- exactly what lets it outlive every cluster.
      coordinateControllerOwnerCluster
        (AwsEbsRetainedFamilyCoordinate "prodbox.io/lifecycle" "retained-ebs")
        `shouldBe` Nothing
      -- A stack coordinate is not itself controller-owned.
      coordinateControllerOwnerCluster
        (AwsPulumiStackCoordinate "prodbox-aws-eks-test" "aws-eks-test")
        `shouldBe` Nothing

    it "exposes a caller-constructible observation only as non-authorizing evidence" $ do
      let observation =
            OwnershipManifestObservation
              { ownershipManifestStackKey = AwsTestKey
              , ownershipManifestProvenance = OwnershipManifestProvenance "authority/model-b"
              , ownershipManifestEvidenceScope = cleanupScope
              , ownershipManifestResult = OwnershipManifestPresent (OwnershipManifestVersion "v1")
              }
          evidence = ownershipManifestObservationOnly observation
      ownershipManifestDecisionStackKey evidence `shouldBe` AwsTestKey
      ownershipManifestDecisionScope evidence `shouldBe` cleanupScope
      ownershipManifestDecisionView evidence
        `shouldBe` OwnershipManifestDecisionObservation observation

    it "rejects a write or cleanup target with the wrong lifecycle operation" $ do
      mkWriteAheadManifestIntent CascadeSurface AwsTestKey cleanupScope
        `shouldSatisfy` isOperationMismatch
      mkOwnershipManifestTarget CascadeSurface AwsTestKey creationScope
        `shouldSatisfy` isOperationMismatch

    it "keeps every raw manifest and legacy authority minter off the public facade" $ do
      facade <- readFile "src/Prodbox/Lifecycle/Teardown/OwnershipManifest.hs"
      let header = unlines (takeWhile (/= "where") (lines facade))
      mapM_
        (header `shouldNotContain`)
        [ "OwnershipManifestReadBackResult"
        , "OwnershipManifestReadBackObservation"
        , "readBackWriteAheadOwnershipManifest"
        , "appendObservedOwnership"
        , "authorizeRegisteredCreate"
        , "bindOwnershipManifestForCleanup"
        , "OwnershipManifestDecisionEvidence (.."
        , "LegacyAdoptionObservation"
        , "renderLegacyAdoptionPlan"
        , "LegacyAdoptionPermitObservation"
        , "bindLegacyAdoptionPermit"
        , "ConfirmedLegacyAdoptionManifestObservation"
        , "readBackConfirmedLegacyAdoptionManifest"
        ]
      header `shouldContain` "OwnershipManifestDecisionEvidence"
      header `shouldContain` "ownershipManifestObservationOnly"
      header
        `shouldContain` "bindObservedDurableWriteAheadOwnershipManifestForCleanup"
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal `shouldContain` "Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal"
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal"
      importers
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/OwnershipManifestRepository.hs"
          , -- Sprint 7.36: the bounded legacy-adoption planner reads the plan
            -- digest type and the registry-derived ownership edges from the
            -- internal module rather than from the facade, because the facade
            -- imports the planner: it is the facade's adoption binder that
            -- consumes a confirmed plan. Importing the facade here would be a
            -- module cycle, so the direction is the deliberate one.
            "src/Prodbox/Lifecycle/Teardown/LegacyAdoptionPlan.hs"
          , "src/Prodbox/Lifecycle/Teardown/OwnershipManifest.hs"
          ]

isOperationMismatch :: Either OwnershipManifestError value -> Bool
isOperationMismatch result = case result of
  Left OwnershipManifestScopeOperationMismatch {} -> True
  _ -> False

isRightEdge :: Either OwnershipManifestError RegisteredOwnershipEdge -> Bool
isRightEdge result = case result of
  Right _ -> True
  Left _ -> False

creationScope :: ObservationEvidenceScope
creationScope = scopeFor ReconcileDesiredPresent

cleanupScope :: ObservationEvidenceScope
cleanupScope = scopeFor ReconcileDesiredAbsent

scopeFor :: LifecycleOperation -> ObservationEvidenceScope
scopeFor operation =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/manifest-opacity")
    (LinuxRke2FoundationId "linux-rke2/home")
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion "ca-central-1")
        )
    )
    operation

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (importNeedle `isInfixOf` contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | ".hs" `isSuffixOf` path]

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
