{-# LANGUAGE OverloadedStrings #-}

-- | One source-bound mutation specification. Preparing bytes does not write a
-- workspace, launch a compiler, establish isolation, or constitute a result.
module Prodbox.Test.ReviewedMutation
  ( ReviewedMutation (..)
  , ReviewedMutationError (..)
  , PreparedMutation
  , reviewedSourcePath
  , reviewedTestPath
  , reviewedAssertion
  , reviewedSourceDigest
  , reviewedPatchDigest
  , preparedMutantDigest
  , preparedMutantBytes
  , prepareReviewedMutation
  )
where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , publicEvidenceDigestText
  )

data ReviewedMutation = M01OverlappingRoots | M02MissingReport
  deriving (Eq, Show)

data ReviewedMutationError
  = MutationSourceTooLarge
  | MutationSourceInvalidUtf8
  | MutationSourceDigestChanged
  | MutationPatchSiteMissing
  | MutationPatchSiteNotUnique
  deriving (Eq, Show)

data PreparedMutation = PreparedMutation !PublicEvidenceDigest !ByteString.ByteString
  deriving (Eq, Show)

reviewedSourcePath :: ReviewedMutation -> FilePath
reviewedSourcePath M01OverlappingRoots = "src/Prodbox/Config/DeploymentScope.hs"
reviewedSourcePath M02MissingReport = "src/Prodbox/Test/ScenarioEvidence.hs"

reviewedTestPath :: ReviewedMutation -> Text
reviewedTestPath M01OverlappingRoots =
  "prodbox-unit.deployment scope coordinates.rejects overlapping roots for the mutation catalog"
reviewedTestPath M02MissingReport =
  "prodbox-unit.scenario evidence comparison.rejects an unbound report for the mutation catalog"

reviewedAssertion :: ReviewedMutation -> Text
reviewedAssertion M01OverlappingRoots = "context.rejects_root_alias"
reviewedAssertion M02MissingReport = "evidence.rejects_unbound_result"

reviewedSourceDigest :: ReviewedMutation -> Text
reviewedSourceDigest M01OverlappingRoots = "e38d6ca4908cfe91172784dc124fc46777e9ef94a3ff456b88543f28e808515a"
reviewedSourceDigest M02MissingReport = "e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1"

-- The hash identifies the domain, target, pinned source and exact old/new
-- bytes. It is not a unified-diff digest and does not authorize a write.
reviewedPatchDigest :: ReviewedMutation -> PublicEvidenceDigest
reviewedPatchDigest mutation =
  hashPublicEvidence $
    Text.intercalate
      "\NUL"
      [ "prodbox-reviewed-mutation-v1"
      , Text.pack (reviewedSourcePath mutation)
      , reviewedSourceDigest mutation
      , reviewedTestPath mutation
      , reviewedAssertion mutation
      , oldSite mutation
      , newSite mutation
      ]

preparedMutantDigest :: PreparedMutation -> PublicEvidenceDigest
preparedMutantDigest (PreparedMutation digest _) = digest

preparedMutantBytes :: PreparedMutation -> ByteString.ByteString
preparedMutantBytes (PreparedMutation _ bytes) = bytes

prepareReviewedMutation
  :: ReviewedMutation -> ByteString.ByteString -> Either ReviewedMutationError PreparedMutation
prepareReviewedMutation mutation bytes
  | ByteString.length bytes > 1048576 = Left MutationSourceTooLarge
  | otherwise = do
      source <- either (const (Left MutationSourceInvalidUtf8)) Right (TextEncoding.decodeUtf8' bytes)
      if publicEvidenceDigestText (hashPublicEvidence source) /= reviewedSourceDigest mutation
        then Left MutationSourceDigestChanged
        else case Text.splitOn (oldSite mutation) source of
          [prefix, suffix] ->
            let mutant = prefix <> newSite mutation <> suffix
             in Right (PreparedMutation (hashPublicEvidence mutant) (TextEncoding.encodeUtf8 mutant))
          [_] -> Left MutationPatchSiteMissing
          _ -> Left MutationPatchSiteNotUnique

oldSite :: ReviewedMutation -> Text
oldSite M01OverlappingRoots =
  "  | rootsOverlap (scopeRoot left) (scopeRoot right) = Left OverlappingDeploymentRoots\n"
oldSite M02MissingReport =
  "  report <- maybe (Left EvidenceReportMissing) Right maybeReport\n"
    <> "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n"

newSite :: ReviewedMutation -> Text
newSite M01OverlappingRoots =
  "  | rootsOverlap (scopeRoot left) (scopeRoot right) && scopeApiPort left == 0 = Left OverlappingDeploymentRoots\n"
newSite M02MissingReport =
  "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n"
    <> "  report <- maybe\n"
    <> "    (Right (ScenarioReport expected (independentTiming independent) (independentPrimary independent) (independentCleanup independent) (independentObservations independent)))\n"
    <> "    Right maybeReport\n"
