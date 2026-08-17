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
          , "src/Prodbox/Lifecycle/Teardown/OwnershipManifest.hs"
          ]

isOperationMismatch :: Either OwnershipManifestError value -> Bool
isOperationMismatch result = case result of
  Left OwnershipManifestScopeOperationMismatch {} -> True
  _ -> False

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
