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

data ReviewedMutation
  = M01OverlappingRoots
  | M02MissingReport
  | M03ProductionUnlock
  | M03VaultIncarnation
  | M04UnknownAsFresh
  | M04MissingAsFresh
  | M05PendingNoChange
  | M04MirrorGenesisAsFresh
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
reviewedSourcePath M03ProductionUnlock = "src/Prodbox/Control/Unlock.hs"
reviewedSourcePath M03VaultIncarnation = "src/Prodbox/Control/Unlock.hs"
reviewedSourcePath M04UnknownAsFresh = "src/Prodbox/Lifecycle/AdmissionHistory.hs"
reviewedSourcePath M04MissingAsFresh = "src/Prodbox/Lifecycle/AdmissionHistory.hs"
reviewedSourcePath M05PendingNoChange = "src/Prodbox/Lifecycle/AdmissionHistory.hs"
reviewedSourcePath M04MirrorGenesisAsFresh = "src/Prodbox/ControlPlane/AdmissionJournalMirror.hs"

reviewedTestPath :: ReviewedMutation -> Text
reviewedTestPath M01OverlappingRoots =
  "prodbox-unit.deployment scope coordinates.rejects overlapping roots for the mutation catalog"
reviewedTestPath M02MissingReport =
  "prodbox-unit.scenario evidence comparison.rejects an unbound report for the mutation catalog"
reviewedTestPath M03ProductionUnlock =
  "prodbox-unit.bootstrap unlock policy.never selects the test self-unseal policy for production for the mutation catalog"
reviewedTestPath M03VaultIncarnation =
  "prodbox-unit.bootstrap unlock policy.initializes only an uninitialized Vault with no unlock object or pending record for the mutation catalog"
reviewedTestPath M04UnknownAsFresh =
  "prodbox-unit.admission history.never recodes an unobservable journal as never admitted for the mutation catalog"
reviewedTestPath M04MissingAsFresh =
  "prodbox-unit.admission history.never relabels missing existing history as never admitted for the mutation catalog"
reviewedTestPath M05PendingNoChange =
  "prodbox-unit.admission history.blocks a no-change answer while an intent is unresolved for the mutation catalog"
reviewedTestPath M04MirrorGenesisAsFresh =
  "prodbox-unit.admission history.never reads a journal mirror without its genesis record as never admitted for the mutation catalog"

reviewedAssertion :: ReviewedMutation -> Text
reviewedAssertion M01OverlappingRoots = "context.rejects_root_alias"
reviewedAssertion M02MissingReport = "evidence.rejects_unbound_result"
reviewedAssertion M03ProductionUnlock = "bootstrap.production_rejects_test_unlock"
reviewedAssertion M03VaultIncarnation = "bootstrap.preserves_vault_incarnation"
reviewedAssertion M04UnknownAsFresh = "lifecycle.unknown_requires_recovery"
reviewedAssertion M04MissingAsFresh = "lifecycle.missing_history_is_not_fresh"
reviewedAssertion M05PendingNoChange = "lifecycle.pending_intent_blocks_noop"
reviewedAssertion M04MirrorGenesisAsFresh = "lifecycle.uninitialized_mirror_is_not_fresh"

reviewedSourceDigest :: ReviewedMutation -> Text
reviewedSourceDigest M01OverlappingRoots = "119f96fc9f9afef3ad91feb98eba09e69c43da5b33a489f8c4521dd7af99992d"
reviewedSourceDigest M02MissingReport = "e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1"
reviewedSourceDigest M03ProductionUnlock = "29374f1c8e05b8c25bc7a6155c07cdbd76685f4772efb19380bf8f5e72df5f07"
reviewedSourceDigest M03VaultIncarnation = "29374f1c8e05b8c25bc7a6155c07cdbd76685f4772efb19380bf8f5e72df5f07"
reviewedSourceDigest M04UnknownAsFresh = "03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da"
reviewedSourceDigest M04MissingAsFresh = "03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da"
reviewedSourceDigest M05PendingNoChange = "03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da"
reviewedSourceDigest M04MirrorGenesisAsFresh = "cb15a8c10fc6de27285f597760830385515331f54eb355fc547a75f3e43e63d6"

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
oldSite M03ProductionUnlock =
  "  Test -> TestSelfUnseal\n  _ -> ProtectedProduction\n"
oldSite M03VaultIncarnation =
  "  state == VaultUninitialized && not objectPresent && not pendingPresent\n"
oldSite M04UnknownAsFresh =
  "  JournalUnobservable reason -> RecoveryRequired (RecoveryJournalUnobservable reason)\n"
oldSite M04MissingAsFresh =
  "  JournalMissing True -> RecoveryRequired RecoveryHistoryMissing\n"
oldSite M05PendingNoChange =
  "  AdmittedPending _ -> False\n  RecoveryRequired _ -> False\n"
oldSite M04MirrorGenesisAsFresh =
  "    Right False -> pure (JournalUnobservable \"the journal was never initialized by this Authority\")\n"
oldSite M01OverlappingRoots =
  "  | rootsOverlap (scopeRoot left) (scopeRoot right) = Left OverlappingDeploymentRoots\n"
oldSite M02MissingReport =
  "  report <- maybe (Left EvidenceReportMissing) Right maybeReport\n"
    <> "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n"

newSite :: ReviewedMutation -> Text
newSite M03ProductionUnlock =
  "  Test -> TestSelfUnseal\n  _ -> TestSelfUnseal\n"
newSite M03VaultIncarnation =
  "  state == VaultUninitialized && (objectPresent || not objectPresent) && not pendingPresent\n"
newSite M04UnknownAsFresh =
  "  JournalUnobservable _ -> NeverAdmitted\n"
newSite M04MissingAsFresh =
  "  JournalMissing True -> NeverAdmitted\n"
newSite M05PendingNoChange =
  "  AdmittedPending _ -> True\n  RecoveryRequired _ -> False\n"
newSite M04MirrorGenesisAsFresh =
  "    Right False -> pure (JournalRead [])\n"
newSite M01OverlappingRoots =
  "  | rootsOverlap (scopeRoot left) (scopeRoot right) && scopeApiPort left == 0 = Left OverlappingDeploymentRoots\n"
newSite M02MissingReport =
  "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n"
    <> "  report <- maybe\n"
    <> "    (Right (ScenarioReport expected (independentTiming independent) (independentPrimary independent) (independentCleanup independent) (independentObservations independent)))\n"
    <> "    Right maybeReport\n"
