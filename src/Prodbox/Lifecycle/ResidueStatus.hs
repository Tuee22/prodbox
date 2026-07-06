-- | Sprint 4.16: typed Pulumi-stack residue status replacing the
-- file-existence predicates that preceded
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 3@.
--
-- A @ResidueStatus@ value carries one of three discoverable states for
-- a Pulumi-managed AWS stack: 'ResidueAbsent', 'ResiduePresent' with
-- structured details, or 'ResidueUnreachable' when the backend cannot
-- be queried (MinIO down, S3 credentials missing, etc.).
--
-- Sprint 4.19: the destructive-teardown **gates** treat per-run
-- 'ResidueUnreachable' as a refusal, not as absent. "I cannot read the
-- per-run Pulumi state backend (MinIO)" is not the same as "the
-- resources are gone" — treating it as absent let @prodbox cluster delete
-- --yes@ silently pass on a degraded cluster (MinIO pod down, state
-- intact on @.data/@), after which @rm .data@ orphaned the live AWS
-- resources. Long-lived 'ResidueUnreachable' has always been a refusal
-- (the operator-owned S3 backend must be reachable before the
-- long-lived @aws-ses@ stack can be presumed safe to destroy or
-- bypass). Sprint 4.20 unifies that gate decision into the single
-- combinator 'residueBlocksTeardownGate' ("present OR unreachable →
-- block"), superseding the per-class @isResiduePresentOrUnknown*@
-- booleans.
--
-- The @--cascade@ path is the deliberate exception: it keeps its own
-- graceful-degradation handling in
-- 'Prodbox.Lifecycle.ResourceRegistry.resourcesToDestroy' (the cluster is being torn
-- down regardless, with the postflight tag sweep as the backstop), and
-- does not route through this gate combinator.
module Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus (..)
  , ResidueDetails (..)
  , ResidueUnreachableReason (..)
  , residueAbsent
  , residuePresentByFileExistence
  , renderResidueStatus
  , renderResidueDetails
  , renderResidueUnreachableReason
  , isResiduePresent
  , isResidueAbsent
  , isResidueUnreachable
  , residueBlocksTeardownGate
  )
where

-- | Source-of-truth status for one Pulumi-managed AWS stack.
data ResidueStatus
  = ResidueAbsent
  | ResiduePresent !ResidueDetails
  | ResidueUnreachable !ResidueUnreachableReason
  deriving (Eq, Show)

-- | Structured evidence that residue is present. The fields are
-- intentionally minimal so the adapter layer (file-existence today,
-- @pulumi stack ls --json@ tomorrow) can populate them without
-- pulling in the full snapshot vocabulary.
data ResidueDetails = ResidueDetails
  { residueEvidence :: !String
  -- ^ One-line operator-visible evidence string, e.g. the snapshot
  -- file path or a MinIO key, suitable for inclusion in error
  -- narratives.
  , residueStackName :: !String
  -- ^ Canonical Pulumi stack name (e.g. @aws-eks@, @aws-ses@).
  }
  deriving (Eq, Show)

-- | Why the backend was unreachable. The constructors are open enough
-- to cover both per-run (MinIO) and long-lived (S3) backends.
data ResidueUnreachableReason
  = -- | The in-cluster MinIO backend could not be reached. The string
    -- carries the underlying transport message.
    ResidueBackendMinioUnreachable !String
  | -- | The long-lived S3 backend could not be reached.
    ResidueBackendS3Unreachable !String
  | -- | The query reached the backend but the response could not be
    -- decoded.
    ResidueQueryFailed !String
  | -- | Source-of-truth query is not yet implemented for this stack;
    -- the carried string names the placeholder evidence the adapter
    -- consulted instead (e.g. @"file-existence: .prodbox-state/..."@).
    ResidueQueryNotImplemented !String
  deriving (Eq, Show)

-- | Convenience constructor.
residueAbsent :: ResidueStatus
residueAbsent = ResidueAbsent

-- | Promote a boolean file-existence check into a 'ResidueStatus'.
-- Retained for the unit-test scaffolding that exercises the
-- 'ResiduePresent' / 'ResidueAbsent' constructors with a synthetic
-- evidence string; the production residue path went live in Sprint
-- 4.16 and queries Pulumi backends directly via
-- 'Prodbox.Lifecycle.LiveResidue'.
residuePresentByFileExistence
  :: String
  -- ^ Canonical Pulumi stack name.
  -> FilePath
  -- ^ Snapshot path that drove the evidence.
  -> Bool
  -- ^ Whether the file exists.
  -> ResidueStatus
residuePresentByFileExistence stackName snapshotPath exists
  | exists =
      ResiduePresent
        ResidueDetails
          { residueEvidence = "file-existence: " ++ snapshotPath
          , residueStackName = stackName
          }
  | otherwise = ResidueAbsent

renderResidueStatus :: ResidueStatus -> String
renderResidueStatus status = case status of
  ResidueAbsent -> "absent"
  ResiduePresent details -> "present (" ++ renderResidueDetails details ++ ")"
  ResidueUnreachable reason -> "unreachable (" ++ renderResidueUnreachableReason reason ++ ")"

renderResidueDetails :: ResidueDetails -> String
renderResidueDetails details =
  residueStackName details ++ "; evidence: " ++ residueEvidence details

renderResidueUnreachableReason :: ResidueUnreachableReason -> String
renderResidueUnreachableReason reason = case reason of
  ResidueBackendMinioUnreachable msg -> "MinIO backend unreachable: " ++ msg
  ResidueBackendS3Unreachable msg -> "S3 backend unreachable: " ++ msg
  ResidueQueryFailed msg -> "backend query failed: " ++ msg
  ResidueQueryNotImplemented msg -> "source-of-truth query not yet implemented (" ++ msg ++ ")"

isResiduePresent :: ResidueStatus -> Bool
isResiduePresent (ResiduePresent _) = True
isResiduePresent _ = False

isResidueAbsent :: ResidueStatus -> Bool
isResidueAbsent ResidueAbsent = True
isResidueAbsent _ = False

isResidueUnreachable :: ResidueStatus -> Bool
isResidueUnreachable (ResidueUnreachable _) = True
isResidueUnreachable _ = False

-- | Sprint 4.20: the single soundness combinator every destructive
-- teardown gate uses to decide whether a resource blocks the command.
-- A resource blocks when it is 'ResiduePresent' (live resources to
-- destroy first) OR 'ResidueUnreachable' (the backend could not be read
-- — "cannot observe" is never silently treated as "absent," because it
-- is not a confirmation that the resources are gone). Only
-- 'ResidueAbsent' (positively observed gone) passes.
--
-- This replaces the pre-Sprint-4.20 per-class booleans
-- (@isResiduePresentOrUnknownPerRun@ / @…LongLived@), which had drifted
-- to different implementations and let the per-run gate silently pass
-- on an unreadable backend (Sprint 4.19 incident). Per-run and
-- long-lived gates now share this decision; they differ only in the
-- refusal *message*, rendered at the call site. The @--cascade@ path
-- keeps its own graceful-degradation handling in
-- 'Prodbox.Lifecycle.ResourceRegistry.resourcesToDestroy' and does not use this gate.
residueBlocksTeardownGate :: ResidueStatus -> Bool
residueBlocksTeardownGate status =
  isResiduePresent status || isResidueUnreachable status
