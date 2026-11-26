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
  = M00FutureDependency
  | M00InvalidRemover
  | M00MissingEvidence
  | M00ForeignEvidence
  | M00MissingCurrentSource
  | M01OverlappingRoots
  | M01ArtifactBytes
  | M01UnconfirmedNode
  | M01UnknownRecreate
  | M01ExternalFamily
  | M01FailedRemoval
  | M01ForeignControl
  | M01UnboundReceipt
  | M01ForeignControllerReceipt
  | M01WrongControllerNode
  | M01ForeignNamespaceCleanup
  | M01ReplacedNamespace
  | M01ForeignScope
  | M01ForeignNetwork
  | M01UnownedPull
  | M01AuthorityUnobservable
  | M01AuthorityFence
  | M01ReceiptOnlyRemoval
  | M02MissingReport
  | M02StaleSource
  | M02WrongScope
  | M02FabricatedSuccess
  | M03ProductionUnlock
  | M03VaultIncarnation
  | M03BackupContent
  | M04UnknownAsFresh
  | M04MissingAsFresh
  | M05PendingNoChange
  | M04MirrorGenesisAsFresh
  | M04IgnoreMirrorCommitment
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
reviewedSourcePath M00FutureDependency =
  "src/Prodbox/CheckCode.hs"
reviewedSourcePath M00InvalidRemover =
  "src/Prodbox/CheckCode.hs"
reviewedSourcePath M00MissingEvidence =
  "src/Prodbox/CheckCode.hs"
reviewedSourcePath M00ForeignEvidence =
  "src/Prodbox/CheckCode.hs"
reviewedSourcePath M00MissingCurrentSource =
  "src/Prodbox/CheckCode.hs"
reviewedSourcePath M01OverlappingRoots = "src/Prodbox/Config/DeploymentScope.hs"
reviewedSourcePath M01ArtifactBytes = "src/Prodbox/Control/NodeRegistryArchive.hs"
reviewedSourcePath M01UnconfirmedNode = "src/Prodbox/Control/Delete.hs"
reviewedSourcePath M01UnknownRecreate = "src/Prodbox/Control/Recreate.hs"
reviewedSourcePath M01ExternalFamily = "src/Prodbox/Control/Reconcile.hs"
reviewedSourcePath M01FailedRemoval = "src/Prodbox/Control/KindNodeRemovalReadback.hs"
reviewedSourcePath M01ForeignControl =
  "src/Prodbox/Control/Delete.hs"
reviewedSourcePath M01UnboundReceipt =
  "src/Prodbox/Control/KindNetworkRecovery.hs"
reviewedSourcePath M01ForeignControllerReceipt =
  "src/Prodbox/Control/KindControllerReceipt.hs"
reviewedSourcePath M01WrongControllerNode =
  "src/Prodbox/Control/Status.hs"
reviewedSourcePath M01ForeignNamespaceCleanup =
  "src/Prodbox/Control/NetworkEnforcement.hs"
reviewedSourcePath M01ReplacedNamespace =
  "src/Prodbox/Control/NetworkEnforcement.hs"
reviewedSourcePath M01ForeignScope =
  "src/Prodbox/Control/DockerConnectedInfo.hs"
reviewedSourcePath M01ForeignNetwork =
  "src/Prodbox/Control/DockerConnectedInfo.hs"
reviewedSourcePath M01UnownedPull =
  "src/Prodbox/Control/KindDockerReadGate.hs"
reviewedSourcePath M01AuthorityUnobservable =
  "src/Prodbox/Control/AuthorityJournalClient.hs"
reviewedSourcePath M01AuthorityFence =
  "src/Prodbox/Control/AuthorityDeploy.hs"
reviewedSourcePath M01ReceiptOnlyRemoval =
  "src/Prodbox/Control/KindNodeRemovalReadback.hs"
reviewedSourcePath M02MissingReport = "src/Prodbox/Test/ScenarioEvidence.hs"
reviewedSourcePath M02StaleSource =
  "src/Prodbox/Test/ScenarioEvidence.hs"
reviewedSourcePath M02WrongScope =
  "src/Prodbox/Test/ScenarioEvidence.hs"
reviewedSourcePath M02FabricatedSuccess =
  "src/Prodbox/Test/ScenarioEvidence.hs"
reviewedSourcePath M03ProductionUnlock = "src/Prodbox/Control/Unlock.hs"
reviewedSourcePath M03VaultIncarnation = "src/Prodbox/Control/Unlock.hs"
reviewedSourcePath M03BackupContent = "src/Prodbox/Control/Backup.hs"
reviewedSourcePath M04UnknownAsFresh = "src/Prodbox/Lifecycle/AdmissionHistory.hs"
reviewedSourcePath M04MissingAsFresh = "src/Prodbox/Lifecycle/AdmissionHistory.hs"
reviewedSourcePath M05PendingNoChange = "src/Prodbox/Lifecycle/AdmissionHistory.hs"
reviewedSourcePath M04MirrorGenesisAsFresh = "src/Prodbox/ControlPlane/AdmissionJournalMirror.hs"
reviewedSourcePath M04IgnoreMirrorCommitment = "src/Prodbox/ControlPlane/AdmissionJournalMirror.hs"

reviewedTestPath :: ReviewedMutation -> Text
reviewedTestPath M00FutureDependency =
  "prodbox-unit.Sprint 0.9 documentation-harmony pure helpers.numerical phase plan contracts.rejects future numerical phase dependencies including range endpoints"
reviewedTestPath M00InvalidRemover =
  "prodbox-unit.Sprint 0.9 documentation-harmony pure helpers.numerical phase plan contracts.checks canonical removal row owners and duplicate identities"
reviewedTestPath M00MissingEvidence =
  "prodbox-unit.Sprint 0.9 documentation-harmony pure helpers.numerical phase plan contracts.requires available scoped evidence and removed owned rows before closure"
reviewedTestPath M00ForeignEvidence =
  "prodbox-unit.Sprint 0.9 documentation-harmony pure helpers.numerical phase plan contracts.requires available scoped evidence and removed owned rows before closure"
reviewedTestPath M00MissingCurrentSource =
  "prodbox-unit.Sprint 0.9 documentation-harmony pure helpers.Sprint 0.21 citedSourcePathsInDoc.refuses missing or escaping source paths"
reviewedTestPath M01OverlappingRoots =
  "prodbox-unit.deployment scope coordinates.rejects overlapping roots for the mutation catalog"
reviewedTestPath M01ArtifactBytes =
  "prodbox-unit.node registry manifest.writes a digest-bound archive and refuses changed source bytes"
reviewedTestPath M01UnconfirmedNode =
  "prodbox-unit.test node artifact preparation.never infers that a node was unstarted from a missing or invalid result alone"
reviewedTestPath M01UnknownRecreate =
  "prodbox-unit.test node artifact preparation.does not treat an invalid or unreadable recreation intent as absent"
reviewedTestPath M01ExternalFamily =
  "prodbox-unit.test node artifact preparation.distinguishes owner-first family intent from externally prepared history"
reviewedTestPath M01FailedRemoval =
  "prodbox-unit.test node artifact preparation.accepts only successful removal replies with recorded receipts"
reviewedTestPath M01ForeignControl =
  "prodbox-unit.test node artifact preparation.only removes the exact created, stopped and isolated absence control"
reviewedTestPath M01UnboundReceipt =
  "prodbox-unit.test node artifact preparation.does not accept missing, failed or unobservable prior removal receipts"
reviewedTestPath M01ForeignControllerReceipt =
  "prodbox-unit.test node artifact preparation.binds a controller worker receipt to the retained operation and refuses changes"
reviewedTestPath M01WrongControllerNode =
  "prodbox-unit.test node artifact preparation.binds a worker receipt to the running recorded node"
reviewedTestPath M01ForeignNamespaceCleanup =
  "prodbox-unit.test node artifact preparation.never deletes a namespace whose creation or UID is unconfirmed"
reviewedTestPath M01ReplacedNamespace =
  "prodbox-unit.test node artifact preparation.does not apply probe resources after the namespace UID changes"
reviewedTestPath M01ForeignScope =
  "prodbox-unit.deployment scope coordinates.refuses foreign or ambiguous kind container inventory"
reviewedTestPath M01ForeignNetwork =
  "prodbox-unit.deployment scope coordinates.refuses a same-ID Docker network reported under a foreign name"
reviewedTestPath M01UnownedPull =
  "prodbox-unit.deployment scope coordinates.closes the kind Docker read gate after a forbidden or failed request"
reviewedTestPath M01AuthorityUnobservable =
  "prodbox-unit.test node artifact preparation.retains early teardown admission across API loss and fences Authority deployment"
reviewedTestPath M01AuthorityFence =
  "prodbox-unit.test node artifact preparation.retains early teardown admission across API loss and fences Authority deployment"
reviewedTestPath M01ReceiptOnlyRemoval =
  "prodbox-unit.test node artifact preparation.requires independent node absence after a successful removal receipt"
reviewedTestPath M02MissingReport =
  "prodbox-unit.scenario evidence comparison.rejects an unbound report for the mutation catalog"
reviewedTestPath M02StaleSource =
  "prodbox-unit.scenario evidence comparison.rejects stale source, binary, generation, run and operation bindings"
reviewedTestPath M02WrongScope =
  "prodbox-unit.scenario evidence comparison.rejects stale source, binary, generation, run and operation bindings"
reviewedTestPath M02FabricatedSuccess =
  "prodbox-unit.scenario evidence comparison.rejects a fabricated success and preserves failed or unobservable outcomes"
reviewedTestPath M03ProductionUnlock =
  "prodbox-unit.bootstrap unlock policy.never selects the test self-unseal policy for production for the mutation catalog"
reviewedTestPath M03VaultIncarnation =
  "prodbox-unit.bootstrap unlock policy.initializes only an uninitialized Vault with no unlock object or pending record for the mutation catalog"
reviewedTestPath M03BackupContent =
  "prodbox-unit.backup content integrity.detects a same-size content change for the mutation catalog"
reviewedTestPath M04UnknownAsFresh =
  "prodbox-unit.admission history.never recodes an unobservable journal as never admitted for the mutation catalog"
reviewedTestPath M04MissingAsFresh =
  "prodbox-unit.admission history.never relabels missing existing history as never admitted for the mutation catalog"
reviewedTestPath M05PendingNoChange =
  "prodbox-unit.admission history.blocks a no-change answer while an intent is unresolved for the mutation catalog"
reviewedTestPath M04MirrorGenesisAsFresh =
  "prodbox-unit.admission history.never reads a journal mirror without its genesis record as never admitted for the mutation catalog"
reviewedTestPath M04IgnoreMirrorCommitment =
  "prodbox-unit.admission history.requires recovery when the journal disappears after its genesis reservation was used"

reviewedAssertion :: ReviewedMutation -> Text
reviewedAssertion M00FutureDependency =
  "plan.rejects_future_dependency"
reviewedAssertion M00InvalidRemover =
  "plan.requires_valid_remover"
reviewedAssertion M00MissingEvidence =
  "plan.requires_bound_evidence"
reviewedAssertion M00ForeignEvidence =
  "plan.requires_bound_evidence"
reviewedAssertion M00MissingCurrentSource =
  "plan.rejects_missing_source"
reviewedAssertion M01OverlappingRoots = "context.rejects_root_alias"
reviewedAssertion M01ArtifactBytes = "artifact.rejects_changed_bytes"
reviewedAssertion M01UnconfirmedNode = "delete.rejects_unconfirmed_node"
reviewedAssertion M01UnknownRecreate = "recreate.rejects_unknown_intent"
reviewedAssertion M01ExternalFamily = "controller.rejects_external_family"
reviewedAssertion M01FailedRemoval = "delete.rejects_failed_removal"
reviewedAssertion M01ForeignControl =
  "delete.rejects_foreign_control"
reviewedAssertion M01UnboundReceipt =
  "delete.rejects_unbound_receipt"
reviewedAssertion M01ForeignControllerReceipt =
  "controller.rejects_foreign_receipt"
reviewedAssertion M01WrongControllerNode =
  "controller.rejects_wrong_node"
reviewedAssertion M01ForeignNamespaceCleanup =
  "network.rejects_foreign_namespace_cleanup"
reviewedAssertion M01ReplacedNamespace =
  "network.rejects_replaced_namespace"
reviewedAssertion M01ForeignScope =
  "context.rejects_foreign_scope"
reviewedAssertion M01ForeignNetwork =
  "context.rejects_foreign_network"
reviewedAssertion M01UnownedPull =
  "context.rejects_unowned_pull"
reviewedAssertion M01AuthorityUnobservable =
  "delete.requires_observed_admission"
reviewedAssertion M01AuthorityFence =
  "delete.fences_authority_deployment"
reviewedAssertion M01ReceiptOnlyRemoval =
  "delete.requires_independent_removal"
reviewedAssertion M02MissingReport = "evidence.rejects_unbound_result"
reviewedAssertion M02StaleSource =
  "evidence.rejects_unbound_result"
reviewedAssertion M02WrongScope =
  "evidence.rejects_unbound_result"
reviewedAssertion M02FabricatedSuccess =
  "evidence.rejects_unbound_result"
reviewedAssertion M03ProductionUnlock = "bootstrap.production_rejects_test_unlock"
reviewedAssertion M03VaultIncarnation = "bootstrap.preserves_vault_incarnation"
reviewedAssertion M03BackupContent = "backup.rejects_same_size_corruption"
reviewedAssertion M04UnknownAsFresh = "lifecycle.unknown_requires_recovery"
reviewedAssertion M04MissingAsFresh = "lifecycle.missing_history_is_not_fresh"
reviewedAssertion M05PendingNoChange = "lifecycle.pending_intent_blocks_noop"
reviewedAssertion M04MirrorGenesisAsFresh = "lifecycle.uninitialized_mirror_is_not_fresh"
reviewedAssertion M04IgnoreMirrorCommitment = "lifecycle.modified_mirror_requires_recovery"

reviewedSourceDigest :: ReviewedMutation -> Text
reviewedSourceDigest M00FutureDependency =
  "db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5"
reviewedSourceDigest M00InvalidRemover =
  "db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5"
reviewedSourceDigest M00MissingEvidence =
  "db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5"
reviewedSourceDigest M00ForeignEvidence =
  "db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5"
reviewedSourceDigest M00MissingCurrentSource =
  "db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5"
reviewedSourceDigest M01OverlappingRoots = "5c03d6f72122af8438cf609c5a51d144774c67bb9fe6cbc79240b66fa3591e12"
reviewedSourceDigest M01ArtifactBytes = "7284e324f79d558274f7afb567f9f2443920371cc9156128d689bf93de74f4e2"
reviewedSourceDigest M01UnconfirmedNode = "7036faac60c71259193bb46ab0bda1f7752bb854d81dff5c7de21864ebd292d0"
reviewedSourceDigest M01UnknownRecreate = "5198083b3503309deb0014aa746718c1731a599014029a1ff20af8d75710f369"
reviewedSourceDigest M01ExternalFamily = "ece7a31811fc8ab93eaddb6ca044bd9f672954878a13415931c3ed1511637461"
reviewedSourceDigest M01FailedRemoval = "bc0b010a6ab203cf5d7bf4e74316f3583a2807acb42c512469f2cd9becc76381"
reviewedSourceDigest M01ForeignControl =
  "7036faac60c71259193bb46ab0bda1f7752bb854d81dff5c7de21864ebd292d0"
reviewedSourceDigest M01UnboundReceipt =
  "2a7e891c2464c374f4ab15c8b212da8c802063eed09ab797e02485217146f1cf"
reviewedSourceDigest M01ForeignControllerReceipt =
  "b8d0a9703e50e4a6289279b760845d148295533fa261187c8eadab4d8f1126ee"
reviewedSourceDigest M01WrongControllerNode =
  "581ccbbd117ec9ebed9aac3b00df662ada24523673845521b25744794875dc5a"
reviewedSourceDigest M01ForeignNamespaceCleanup =
  "7c7dc233a4f597258868548e2ca7b489d7bf8b72b949e216447b9b0985409539"
reviewedSourceDigest M01ReplacedNamespace =
  "7c7dc233a4f597258868548e2ca7b489d7bf8b72b949e216447b9b0985409539"
reviewedSourceDigest M01ForeignScope =
  "e36f928e3370ecad2433dc753d2f53ae1c8af85cc214db1842b9dcdc8f304d20"
reviewedSourceDigest M01ForeignNetwork =
  "e36f928e3370ecad2433dc753d2f53ae1c8af85cc214db1842b9dcdc8f304d20"
reviewedSourceDigest M01UnownedPull =
  "e6d5e8de5018e6682c007baa317d030dfa12b2736ee93a0d4245f46a495054d3"
reviewedSourceDigest M01AuthorityUnobservable =
  "9e2f68318192293a74189bc8de465a7d97df1e80bd30445b3c54657429b7c2c2"
reviewedSourceDigest M01AuthorityFence =
  "dc9db941adcb13581209d04773c281d4a1764eab3872465a80a1aee838eb9d67"
reviewedSourceDigest M01ReceiptOnlyRemoval =
  "bc0b010a6ab203cf5d7bf4e74316f3583a2807acb42c512469f2cd9becc76381"
reviewedSourceDigest M02MissingReport = "e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1"
reviewedSourceDigest M02StaleSource =
  "e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1"
reviewedSourceDigest M02WrongScope =
  "e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1"
reviewedSourceDigest M02FabricatedSuccess =
  "e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1"
reviewedSourceDigest M03ProductionUnlock = "ca2b33da348d85b5ecd16dd66ff01a6729453b2d7bfe4e4cd3c9ce4f20d4ce09"
reviewedSourceDigest M03VaultIncarnation = "ca2b33da348d85b5ecd16dd66ff01a6729453b2d7bfe4e4cd3c9ce4f20d4ce09"
reviewedSourceDigest M03BackupContent = "c04744eb50e05203f065b9b7a075573ea77bfc77aa38b652fbecdae60aa9ffac"
reviewedSourceDigest M04UnknownAsFresh = "03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da"
reviewedSourceDigest M04MissingAsFresh = "03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da"
reviewedSourceDigest M05PendingNoChange = "03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da"
reviewedSourceDigest M04MirrorGenesisAsFresh = "e0029b4e3483c56b049b8ce3093372fbff0befc0ad775d7cdc00200982a3b3bd"
reviewedSourceDigest M04IgnoreMirrorCommitment = "e0029b4e3483c56b049b8ce3093372fbff0befc0ad775d7cdc00200982a3b3bd"

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
oldSite M03BackupContent =
  "                    else let nextState = HMAC.update state chunk in nextState `seq` consume nextState\n"
oldSite M04UnknownAsFresh =
  "  JournalUnobservable reason -> RecoveryRequired (RecoveryJournalUnobservable reason)\n"
oldSite M04MissingAsFresh =
  "  JournalMissing True -> RecoveryRequired RecoveryHistoryMissing\n"
oldSite M05PendingNoChange =
  "  AdmittedPending _ -> False\n  RecoveryRequired _ -> False\n"
oldSite M04MirrorGenesisAsFresh =
  "      JournalMemberMissing -> pure (JournalUnobservable \"the journal was never initialized by this Authority\")\n"
oldSite M04IgnoreMirrorCommitment =
  "        pure (closing == Just expected && hexSha256 bytes == expected)\n"
oldSite M00FutureDependency =
  "                , dependency >= owner\n"
oldSite M00InvalidRemover =
  "    , length cells < 5\n        || cellAt 2 cells `notElem` map show [0 :: Int .. 10]\n"
oldSite M00MissingEvidence =
  "          ++ [path ++ \" has no available linked evidence record.\" | null evidenceContents]\n"
oldSite M00ForeignEvidence =
  "          , [show owner]\n              == [dropWhile isSpace value | line <- lines content, Just value <- [stripPrefix \"**Phase**:\" line]]\n"
oldSite M00MissingCurrentSource =
  "          if outside || private then pure False else doesFileExist target\n"
oldSite M01OverlappingRoots =
  "  | rootsOverlap (scopeRoot left) (scopeRoot right) = Left OverlappingDeploymentRoots\n"
oldSite M01ArtifactBytes =
  "              && \"sha256:\" <> Text.pack (show (hashFinalize context :: Digest SHA256)) == nodeRegistryBlobDigest blob\n"
oldSite M01UnconfirmedNode =
  "nodeNeverStarted result attempted = result == NodeCreateResultMissing && attempted == Just False\n"
oldSite M01UnknownRecreate =
  "  KindIntentObservationUnobservable -> ArchiveIntentUnconfirmed\n"
oldSite M01ExternalFamily =
  "      protocol <- observeKindOwnerFamilyIntent bootstrap\n"
    <> "      after <- admission stable\n"
    <> "      pure (before && protocol == KindIntentMatches operation && after)\n"
    <> "    if admitted"
oldSite M01FailedRemoval =
  "  NodeRemoveResultObserved (DockerNodeContainerRemoveReply 204) -> True\n"
oldSite M01ForeignControl =
  "    && fmap words inspected == Just [identifier, '/' : name, operation, \"false\", \"none\"]\n"
oldSite M01UnboundReceipt =
  "priorNetworkRemovalRecorded observed = case observed of\n  NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 204)) -> True\n  _ -> False\n"
oldSite M01ForeignControllerReceipt =
  "              if value == receiptValue bootstrap operation identifier root\n"
oldSite M01WrongControllerNode =
  "    (Just (Right (DockerNodeContainerMatching True))) -> identifier == recorded\n"
oldSite M01ForeignNamespaceCleanup =
  "    case createdNamespaceUid created of\n      Nothing ->\n        pure\n"
oldSite M01ReplacedNamespace =
  "    if createdNamespaceUid current == Just uid\n      then execute arguments input\n"
oldSite M01ForeignScope =
  "    if not (validImageId (\"sha256:\" ++ identifier)) || label /= cluster || names /= [\"/\" ++ expectedName]\n"
oldSite M01ForeignNetwork =
  "    || name /= scopeKindName scope\n    || actualId /= identifier\n    || null driver\n"
oldSite M01UnownedPull =
  "  [\"inspect\", \"--type=image\", requested]\n    | requested == imageId -> Just (KindDockerImage imageId)\n"
oldSite M01AuthorityUnobservable =
  "      (other, FromAuthority _) -> pure (Left (renderVerdict other))\n  admitRetained"
oldSite M01AuthorityFence =
  "    if checkpoint == KindIntentMissing && archive == Right True && idle && held && admitted\n"
oldSite M01ReceiptOnlyRemoval =
  "  if nodeRemovalInventoryEmpty inventory then exactAbsence else pure False\n"
oldSite M02MissingReport =
  "  report <- maybe (Left EvidenceReportMissing) Right maybeReport\n"
    <> "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n"
oldSite M02StaleSource =
  "  require (reportBinding report == expected) EvidenceReportBindingMismatch\n"
oldSite M02WrongScope =
  "  require (reportBinding report == expected) EvidenceReportBindingMismatch\n"
oldSite M02FabricatedSuccess =
  "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n  require (reportBinding report == expected) EvidenceReportBindingMismatch\n"

newSite :: ReviewedMutation -> Text
newSite M03ProductionUnlock =
  "  Test -> TestSelfUnseal\n  _ -> TestSelfUnseal\n"
newSite M03VaultIncarnation =
  "  state == VaultUninitialized && (objectPresent || not objectPresent) && not pendingPresent\n"
newSite M03BackupContent =
  "                    else consume state\n"
newSite M04UnknownAsFresh =
  "  JournalUnobservable _ -> NeverAdmitted\n"
newSite M04MissingAsFresh =
  "  JournalMissing True -> NeverAdmitted\n"
newSite M05PendingNoChange =
  "  AdmittedPending _ -> True\n  RecoveryRequired _ -> False\n"
newSite M04MirrorGenesisAsFresh =
  "      JournalMemberMissing -> pure (JournalRead [])\n"
newSite M04IgnoreMirrorCommitment =
  "        pure (closing == Just expected && (hexSha256 bytes == expected || closing /= Nothing))\n"
newSite M00FutureDependency =
  "                , dependency == owner\n"
newSite M00InvalidRemover =
  "    , length cells < 5\n        || cellAt 2 cells `notElem` map show [0 :: Int .. 11]\n"
newSite M00MissingEvidence =
  ""
newSite M00ForeignEvidence =
  ""
newSite M00MissingCurrentSource =
  "          if outside || private then pure False else pure True\n"
newSite M01OverlappingRoots =
  "  | rootsOverlap (scopeRoot left) (scopeRoot right) && scopeApiPort left == 0 = Left OverlappingDeploymentRoots\n"
newSite M01ArtifactBytes =
  "              && (True || \"sha256:\" <> Text.pack (show (hashFinalize context :: Digest SHA256)) == nodeRegistryBlobDigest blob)\n"
newSite M01UnconfirmedNode =
  "nodeNeverStarted result attempted = result == NodeCreateResultMissing && (attempted == Just False || attempted == Just True)\n"
newSite M01UnknownRecreate =
  "  KindIntentObservationUnobservable -> ArchiveNoIntent\n"
newSite M01ExternalFamily =
  "      protocol <- const (KindIntentMatches operation) <$> observeKindOwnerFamilyIntent bootstrap\n"
    <> "      after <- admission stable\n"
    <> "      pure (before && protocol == KindIntentMatches operation && after)\n"
    <> "    if admitted"
newSite M01FailedRemoval =
  "  NodeRemoveResultObserved (DockerNodeContainerRemoveReply _) -> True\n"
newSite M01ForeignControl =
  "    && not (null name)\n    && case fmap words inspected of\n      Just [actualId, _, actualOperation, \"false\", \"none\"] -> actualId == identifier && actualOperation == operation\n      _ -> False\n"
newSite M01UnboundReceipt =
  "priorNetworkRemovalRecorded observed = case observed of\n  NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 204)) -> True\n  NetworkReceiptInvalid -> True\n  _ -> False\n"
newSite M01ForeignControllerReceipt =
  "              let recorded = either (const operation) id (parseEither (Aeson.withObject \"controller receipt\" (.: \"operation_id\")) value)\n               in if value == receiptValue bootstrap recorded identifier root\n"
newSite M01WrongControllerNode =
  "    (Just (Right (DockerNodeContainerMatching True))) -> length identifier == length recorded\n"
newSite M01ForeignNamespaceCleanup =
  "    case createdNamespaceUid created of\n      Nothing -> do\n        _ <- execute [\"delete\", \"namespace\", namespace] ByteString.empty\n        pure\n"
newSite M01ReplacedNamespace =
  "    if maybe False ((== length uid) . length) (createdNamespaceUid current)\n      then execute arguments input\n"
newSite M01ForeignScope =
  "    if not (validImageId (\"sha256:\" ++ identifier)) || null (label :: String) || names /= [\"/\" ++ expectedName]\n"
newSite M01ForeignNetwork =
  "    || (null (name :: String) && name /= scopeKindName scope)\n    || actualId /= identifier\n    || null driver\n"
newSite M01UnownedPull =
  "  [\"pull\", requested]\n    | requested == imageId -> Just (KindDockerImage imageId)\n  [\"inspect\", \"--type=image\", requested]\n    | requested == imageId -> Just (KindDockerImage imageId)\n"
newSite M01AuthorityUnobservable =
  "      (other, FromAuthority _) -> pure (case other of {RecoveryRequired (RecoveryJournalUnobservable _) -> Right (); _ -> Left (renderVerdict other)})\n  admitRetained"
newSite M01AuthorityFence =
  "    if (checkpoint == KindIntentMissing || checkpoint /= KindIntentMissing) && archive == Right True && idle && held && admitted\n"
newSite M01ReceiptOnlyRemoval =
  "  if nodeRemovalInventoryEmpty inventory then exactAbsence else pure True\n"
newSite M02MissingReport =
  "  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n"
    <> "  report <- maybe\n"
    <> "    (Right (ScenarioReport expected (independentTiming independent) (independentPrimary independent) (independentCleanup independent) (independentObservations independent)))\n"
    <> "    Right maybeReport\n"
newSite M02StaleSource =
  "  require ((reportBinding report) {scenarioSource = scenarioSource expected} == expected) EvidenceReportBindingMismatch\n"
newSite M02WrongScope =
  "  require ((reportBinding report) {scenarioScope = scenarioScope expected} == expected) EvidenceReportBindingMismatch\n"
newSite M02FabricatedSuccess =
  "  rawIndependent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent\n  let independent = rawIndependent {independentPrimary = reportPrimary report}\n  require (reportBinding report == expected) EvidenceReportBindingMismatch\n"
