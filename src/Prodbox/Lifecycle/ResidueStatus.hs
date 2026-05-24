-- | Sprint 4.16: typed Pulumi-stack residue status replacing the
-- file-existence predicates that preceded
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 3@.
--
-- A @ResidueStatus@ value carries one of three discoverable states for
-- a Pulumi-managed AWS stack: 'ResidueAbsent', 'ResiduePresent' with
-- structured details, or 'ResidueUnreachable' when the backend cannot
-- be queried (MinIO down, S3 credentials missing, etc.).
--
-- Per the lifecycle reconciliation doctrine, callers treat per-run
-- 'ResidueUnreachable' as residue-absent (graceful degradation when the
-- in-cluster MinIO backend is gone) and long-lived 'ResidueUnreachable'
-- as a refusal (the operator-owned S3 backend must be reachable before
-- the long-lived @aws-ses@ stack can be presumed safe to destroy or
-- bypass). The helpers 'isResiduePresentOrUnknownPerRun' /
-- 'isResiduePresentOrUnknownLongLived' encode that asymmetry so call
-- sites do not branch on the constructor directly.
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
  , isResiduePresentOrUnknownPerRun
  , isResiduePresentOrUnknownLongLived
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
-- The adapter layer used by Sprint 4.16's initial landing wraps the
-- legacy @<stack>HasLiveResources@ predicate; later sprints will
-- replace this with real backend queries that produce
-- 'ResidueUnreachable' when the backend is down.
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

-- | Per-run callers treat unreachable backends as residue-absent — if
-- MinIO is gone the in-cluster stack snapshot cannot survive, so the
-- safe assumption is that there is nothing left to refuse on.
isResiduePresentOrUnknownPerRun :: ResidueStatus -> Bool
isResiduePresentOrUnknownPerRun = isResiduePresent

-- | Long-lived callers treat unreachable backends as still-present —
-- the S3-backed @aws-ses@ stack must be confirmed gone before any
-- refusal can be relaxed.
isResiduePresentOrUnknownLongLived :: ResidueStatus -> Bool
isResiduePresentOrUnknownLongLived status =
  isResiduePresent status || isResidueUnreachable status
