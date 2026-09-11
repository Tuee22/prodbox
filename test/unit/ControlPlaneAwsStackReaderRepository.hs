{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneAwsStackReaderRepository
  ( controlPlaneAwsStackReaderRepositorySuite
  )
where

import Control.Monad (filterM)
import Data.ByteString qualified as ByteString
import Data.List (isInfixOf, isSuffixOf, sort)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AwsStackReaderRepository
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

controlPlaneAwsStackReaderRepositorySuite :: SuiteBuilder ()
controlPlaneAwsStackReaderRepositorySuite =
  describe "Authority AWS stack-reader capability boundary" $ do
    it "keeps the stable Authority identity canonical and fully scoped" $ do
      let identity = fixtureIdentity
          submission =
            awsStackReaderSubmissionKeyText
              (awsStackReaderAuthoritySubmissionKey identity)
          encoded = encodeAwsStackReaderAuthorityIdentity identity
      awsStackReaderAuthorityRunId identity `shouldBe` fixtureRunId
      awsStackReaderAuthorityGraphDigest identity `shouldBe` fixtureGraphDigest
      awsStackReaderAuthorityOperationId identity `shouldBe` fixtureOperationId
      awsStackReaderAuthorityKey identity `shouldBe` AwsTestKey
      awsStackReaderAuthorityCoordinateDigest identity
        `shouldBe` registeredIdentityCoordinateDigest (mustIdentity AwsTestKey)
      awsStackReaderAuthorityScope identity `shouldBe` fixtureScope
      submission `shouldSatisfy` Text.isPrefixOf "aws-stack-reader-v2-"
      Text.length submission `shouldBe` 84
      awsStackReaderAuthorityLogicalName identity
        `shouldBe` ("authority/aws-stack-readers/" <> submission)
      ByteString.length encoded
        `shouldSatisfy` (<= maximumAwsStackReaderAuthorityIdentityBytes)
      decodeAwsStackReaderAuthorityIdentity encoded `shouldBe` Right identity
      decodeAwsStackReaderAuthorityIdentity (encoded <> "trailing")
        `shouldSatisfy` isIdentityDecodeFailure

    -- Sprint 6.5: the live cascade committed a bundle and then refused its own
    -- read-back, because the encoded scope carried no DNS hosted zone and the
    -- exact identity comparator required one.  The zone is part of the scope,
    -- so it has to survive the wire and separate two otherwise identical
    -- identities.
    it "binds the run DNS hosted zone into the encoded scope and the submission key" $ do
      let zonedIdentity = fixtureZonedIdentity
          zonedEncoded = encodeAwsStackReaderAuthorityIdentity zonedIdentity
          zonedSubmission =
            awsStackReaderSubmissionKeyText
              (awsStackReaderAuthoritySubmissionKey zonedIdentity)
          plainSubmission =
            awsStackReaderSubmissionKeyText
              (awsStackReaderAuthoritySubmissionKey fixtureIdentity)
          otherZonedSubmission =
            awsStackReaderSubmissionKeyText
              (awsStackReaderAuthoritySubmissionKey (zonedIdentityFor "Z9999999999999"))
      evidenceAwsDnsZone (awsStackReaderAuthorityScope zonedIdentity)
        `shouldBe` Just fixtureHostedZone
      evidenceAwsDnsZone (awsStackReaderAuthorityScope fixtureIdentity)
        `shouldBe` Nothing
      decodeAwsStackReaderAuthorityIdentity zonedEncoded `shouldBe` Right zonedIdentity
      fmap
        (evidenceAwsDnsZone . awsStackReaderAuthorityScope)
        (decodeAwsStackReaderAuthorityIdentity zonedEncoded)
        `shouldBe` Right (Just fixtureHostedZone)
      fmap
        (evidenceAwsDnsZone . awsStackReaderAuthorityScope)
        ( decodeAwsStackReaderAuthorityIdentity
            (encodeAwsStackReaderAuthorityIdentity fixtureIdentity)
        )
        `shouldBe` Right Nothing
      zonedSubmission `shouldSatisfy` (/= plainSubmission)
      zonedSubmission `shouldSatisfy` (/= otherZonedSubmission)
      ByteString.length zonedEncoded
        `shouldSatisfy` (<= maximumAwsStackReaderAuthorityIdentityBytes)

    it "exposes only a structurally fail-only public diagnostic client" $ do
      let expected = AwsStackReaderClientTransportFailed "diagnostic refusal"
          client = nonAuthorizingAwsStackReaderDiagnosticClient expected
      independentlyReadBackCommittedAwsStackReaderBundle
        client
        fixtureOperationId
        AwsTestKey
        fixtureScope
        `shouldReturnSatisfying` isExpectedFailure
      readBackAwsStackDecisionInputs
        client
        fixtureOperationId
        AwsTestKey
        fixtureScope
        `shouldReturnSatisfying` isDiagnosticText
      readBackAwsStackProviderBinding
        client
        fixtureOperationId
        AwsTestKey
        fixtureScope
        `shouldReturnSatisfying` isDiagnosticText

    it "keeps all byte/repository/remint capabilities package-private" $ do
      facade <- readFile "src/Prodbox/ControlPlane/AwsStackReaderRepository.hs"
      endpoint <- readFile "src/Prodbox/ControlPlane/AwsStackReaderEndpoint.hs"
      internal <-
        readFile "src/Prodbox/ControlPlane/AwsStackReaderRepository/Internal.hs"
      let facadeHeader = moduleHeader facade
          endpointHeader = moduleHeader endpoint
      mapM_
        (facadeHeader `shouldNotContain`)
        [ "  , AwsStackReaderBundle\n"
        , "prepareAwsStackReaderBundle"
        , "decodeAwsStackReaderBundle"
        , "awsStackReaderBundleBytes"
        , "AwsStackReaderReadBackObservation"
        , "AwsStackReaderRepository (.."
        , "awsStackReaderModelBCodec"
        , "modelBAwsStackReaderRepository"
        , "confirmCommittedAwsStackReaderBytes"
        , "AwsStackReaderClient (.."
        , "lifecycleAuthorityAwsStackReaderClient"
        ]
      facadeHeader `shouldContain` "AwsStackReaderClient"
      facadeHeader `shouldContain` "CommittedAwsStackReaderBundle"
      facadeHeader
        `shouldContain` "nonAuthorizingAwsStackReaderDiagnosticClient"
      endpointHeader
        `shouldNotContain` "confirmAwsStackReaderReadBackResponse"
      internal `shouldContain` "AwsStackReaderCompleteManifestUnsupported"
      internal `shouldContain` "ManifestCompleteWire"

    it "restricts hidden readers and transport construction to the Authority implementation" $ do
      internalImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.AwsStackReaderRepository.Internal"
      internalImporters
        `shouldBe` sort
          [ "src/Prodbox/ControlPlane/AwsStackReaderEndpoint.hs"
          , "src/Prodbox/ControlPlane/AwsStackReaderRepository.hs"
          , "src/Prodbox/ControlPlane/AwsStackReaderTransportClient.hs"
          , "src/Prodbox/ControlPlane/Runtime.hs"
          ]
      transportImporters <-
        sourceImporters
          "src"
          "import Prodbox.ControlPlane.AwsStackReaderTransportClient"
      -- Sprint 4.86: the host-side authenticated client had no importer at
      -- all, which is what made the production cloud runtime unbuildable.  Its
      -- one production constructor is named here deliberately, and the module
      -- stays Cabal-hidden so nothing outside the library can build one.
      transportImporters
        `shouldBe` ["src/Prodbox/Lifecycle/Teardown/CloudRuntimeProduction.hs"]
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.ControlPlane.AwsStackReaderRepository.Internal"
      cabal
        `shouldContain` "Prodbox.ControlPlane.AwsStackReaderTransportClient"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.AwsStackReaderRepository.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.ControlPlane.AwsStackReaderTransportClient"

fixtureIdentity :: AwsStackReaderAuthorityIdentity
fixtureIdentity =
  mustRight
    ( awsStackReaderAuthorityIdentity
        fixtureRunId
        fixtureGraphDigest
        fixtureOperationId
        AwsTestKey
        fixtureScope
    )

fixtureZonedIdentity :: AwsStackReaderAuthorityIdentity
fixtureZonedIdentity = zonedIdentityFor "Z00231272QFGWVE1AJI2G"

zonedIdentityFor :: Text.Text -> AwsStackReaderAuthorityIdentity
zonedIdentityFor rawZone =
  mustRight
    ( awsStackReaderAuthorityIdentity
        fixtureRunId
        fixtureGraphDigest
        fixtureOperationId
        AwsTestKey
        (fixtureScopeWithZone (mustZone rawZone))
    )

fixtureHostedZone :: HostedZoneId
fixtureHostedZone = mustZone "Z00231272QFGWVE1AJI2G"

mustZone :: Text.Text -> HostedZoneId
mustZone raw = case mkHostedZoneId raw of
  Left err -> error ("expected a hosted zone, got " <> show err)
  Right zone -> zone

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/stack-reader-opacity")

fixtureGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))

fixtureOperationId :: CleanupOperationId
fixtureOperationId =
  mustRight (mkCleanupOperationId "reconcile-registered-stack/aws-test")

fixtureScope :: ObservationEvidenceScope
fixtureScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/stack-reader-opacity")
    (LinuxRke2FoundationId "linux-rke2/home")
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

fixtureScopeWithZone :: HostedZoneId -> ObservationEvidenceScope
fixtureScopeWithZone zone =
  mkObservationEvidenceScopeWithDnsZone
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/stack-reader-opacity")
    (LinuxRke2FoundationId "linux-rke2/home")
    ( Just
        ( AwsScope
            (AwsAccountId "111122223333")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    zone
    ReconcileDesiredAbsent

isIdentityDecodeFailure :: Either AwsStackReaderError value -> Bool
isIdentityDecodeFailure result = case result of
  Left _ -> True
  Right _ -> False

isExpectedFailure
  :: Either AwsStackReaderClientError value -> Bool
isExpectedFailure result = case result of
  Left (AwsStackReaderClientTransportFailed "diagnostic refusal") -> True
  _ -> False

isDiagnosticText :: Either Text.Text value -> Bool
isDiagnosticText result = case result of
  Left "non-authorizing AWS stack-reader diagnostic client" -> True
  _ -> False

shouldReturnSatisfying :: IO value -> (value -> Bool) -> Expectation
shouldReturnSatisfying action predicate = do
  value <- action
  value `shouldSatisfy` predicate

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registry identity: " <> show key)
  Just identity -> identity

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error ("expected Right, got " <> show err)
  Right value -> value

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
