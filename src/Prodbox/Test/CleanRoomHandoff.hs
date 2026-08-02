{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Test.CleanRoomHandoff
  ( CleanRoomAction (..)
  , CleanRoomPrefixRefusal (..)
  , RollbackDisposition (..)
  , LegacyResidue (..)
  , canonicalCleanRoomActions
  , resumeCleanRoomActions
  , rollbackDisposition
  , forbiddenLegacyPaths
  , forbiddenLegacyFragments
  , legacyResidueViolations
  , renderCleanRoomPlan
  )
where

import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text

-- | The versioned, installed-binary clean-room contract. Each constructor is
-- an observable boundary at which interruption and restart must be safe.
data CleanRoomAction
  = ObserveLegacyRetainedState
  | ImportAuthorityProjections
  | VerifyAuthorityShadow
  | FreezeLegacyWriter
  | ActivateReplacementEpoch
  | RefusePostCutoverRollback
  | DeleteCluster
  | ReconcileCluster
  | ObserveVaultSealed
  | UnsealVault
  | CompleteBrokerHandoff
  | ReplayAuthorityJournal
  | RestoreGateway
  | RestoreTargetAgent
  | RestoreCharts
  | AttemptAlwaysRunCleanup
  | VerifyZeroLegacyResidue
  | CommitQualificationEvidence
  deriving (Eq, Ord, Show, Enum, Bounded)

data CleanRoomPrefixRefusal
  = CleanRoomUnknownAction CleanRoomAction
  | CleanRoomSkippedOrReordered
      { expectedNextAction :: CleanRoomAction
      , observedAction :: CleanRoomAction
      }
  | CleanRoomActionsAfterCompletion
  deriving (Eq, Show)

data RollbackDisposition
  = RetryLegacyObservation
  | RefuseRollbackBeforeMutation
  deriving (Eq, Show)

data LegacyResidue
  = LegacyPathPresent FilePath
  | LegacyFragmentPresent FilePath Text
  deriving (Eq, Ord, Show)

canonicalCleanRoomActions :: [CleanRoomAction]
canonicalCleanRoomActions = [minBound .. maxBound]

-- | Accept only an exact durable prefix. A restart resumes the first missing
-- boundary; skips, reordering, duplicates, and suffixes after completion are
-- explicit refusals rather than best-effort recovery.
resumeCleanRoomActions
  :: [CleanRoomAction]
  -> Either CleanRoomPrefixRefusal [CleanRoomAction]
resumeCleanRoomActions completed = go canonicalCleanRoomActions completed
 where
  go remaining [] = Right remaining
  go [] (_ : _) = Left CleanRoomActionsAfterCompletion
  go (expected : remaining) (observed : observations)
    | observed `notElem` canonicalCleanRoomActions = Left (CleanRoomUnknownAction observed)
    | observed == expected = go remaining observations
    | otherwise = Left (CleanRoomSkippedOrReordered expected observed)

rollbackDisposition :: [CleanRoomAction] -> RollbackDisposition
rollbackDisposition completed
  | ActivateReplacementEpoch `elem` completed = RefuseRollbackBeforeMutation
  | otherwise = RetryLegacyObservation

forbiddenLegacyPaths :: [FilePath]
forbiddenLegacyPaths =
  [ "src/Prodbox/Gateway/ObjectStore.hs"
  , "src/Prodbox/Gateway/TargetSecret.hs"
  , "src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs"
  , "src/Prodbox/Lifecycle/TargetSecretStore.hs"
  , "src/Prodbox/Pulumi/HostDirectObjectStore.hs"
  , "src/Prodbox/ControlPlane/TargetSecretEndpoint.hs"
  ]

forbiddenLegacyFragments :: [Text]
forbiddenLegacyFragments =
  [ "Prodbox.Gateway.ObjectStore"
  , "Prodbox.Gateway.TargetSecret"
  , "Prodbox.Lifecycle.HostDirectAuthorityStore"
  , "Prodbox.Lifecycle.TargetSecretStore"
  , "Prodbox.Pulumi.HostDirectObjectStore"
  , "Prodbox.ControlPlane.TargetSecretEndpoint"
  , "prodbox-gateway-target-secret"
  ]

legacyResidueViolations
  :: [FilePath]
  -> [(FilePath, Text)]
  -> [LegacyResidue]
legacyResidueViolations paths sources =
  [ LegacyPathPresent path
  | path <- forbiddenLegacyPaths
  , path `elem` paths
  ]
    ++ [ LegacyFragmentPresent path fragment
       | (path, source) <- sources
       , fragment <- forbiddenLegacyFragments
       , Text.unpack fragment `isInfixOf` Text.unpack source
       ]

renderCleanRoomPlan :: [CleanRoomAction] -> String
renderCleanRoomPlan completed =
  unlines
    ( [ "CLEAN_ROOM_HANDOFF_PLAN"
      , "SCHEMA_VERSION=1"
      , "ROLLBACK=" ++ renderRollback (rollbackDisposition completed)
      ]
        ++ either renderRefusal (map (("STEP=" ++) . renderAction)) (resumeCleanRoomActions completed)
    )
 where
  renderRollback disposition = case disposition of
    RetryLegacyObservation -> "retry-legacy-observation"
    RefuseRollbackBeforeMutation -> "refuse-before-mutation"
  renderRefusal refusal = ["REFUSED=" ++ show refusal]

renderAction :: CleanRoomAction -> String
renderAction action = case action of
  ObserveLegacyRetainedState -> "observe-legacy-retained-state"
  ImportAuthorityProjections -> "import-authority-projections"
  VerifyAuthorityShadow -> "verify-authority-shadow"
  FreezeLegacyWriter -> "freeze-legacy-writer"
  ActivateReplacementEpoch -> "activate-replacement-epoch"
  RefusePostCutoverRollback -> "refuse-post-cutover-rollback"
  DeleteCluster -> "cluster-delete"
  ReconcileCluster -> "cluster-reconcile"
  ObserveVaultSealed -> "observe-vault-sealed"
  UnsealVault -> "unseal-vault"
  CompleteBrokerHandoff -> "complete-broker-handoff"
  ReplayAuthorityJournal -> "replay-authority-journal"
  RestoreGateway -> "restore-gateway"
  RestoreTargetAgent -> "restore-target-agent"
  RestoreCharts -> "restore-charts"
  AttemptAlwaysRunCleanup -> "attempt-always-run-cleanup"
  VerifyZeroLegacyResidue -> "verify-zero-legacy-residue"
  CommitQualificationEvidence -> "commit-qualification-evidence"
