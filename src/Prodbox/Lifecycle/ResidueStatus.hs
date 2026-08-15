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
  , ResidueObservationLayer (..)
  , renderResidueObservationLayer
  , ResidueObservation
  , observeResidueAt
  , residueObservationLayer
  , residueObservationStatus
  , mapResidueObservationStatus
  , AwsLayerAnswer (..)
  , ResidueResolution (..)
  , resolveResidueAcrossLayers
  , residueResolutionStatus
  , residueResolutionConfirmedAbsence
  , renderResidueResolution
  , renderAwsLayerAnswer
  , ResidueDetails (..)
  , ResidueUnreachableReason (..)
  , ObservationFailure (..)
  , CheckpointFailure (..)
  , PresenceObservation (..)
  , CheckpointObservation (..)
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

-- | A failure to classify an externally authoritative fact. The operation is
-- kept separate from the underlying detail so callers can render a precise
-- refusal without parsing an exception string. Authentication, authorization,
-- throttling, transport, and decode failures all remain in this constructor;
-- none may be recoded as absence.
data ObservationFailure = ObservationFailure
  { observationFailureOperation :: !String
  , observationFailureDetail :: !String
  }
  deriving (Eq, Show)

-- | Evidence that a checkpoint object was positively read but could not be
-- decoded as a usable snapshot. Corruption is distinct from a missing object
-- and from an authority that could not be reached.
data CheckpointFailure = CheckpointFailure
  { checkpointFailureDetail :: !String
  }
  deriving (Eq, Show)

-- | Flat observation of authoritative resource presence. The payload is the
-- finite inventory observed at the external authority.
data PresenceObservation inventory
  = PresenceAbsent
  | PresencePresent !inventory
  | PresenceUnobservable !ObservationFailure
  deriving (Eq, Show)

-- | Flat observation of retained checkpoint usability. This is deliberately
-- independent of 'PresenceObservation': live resources and a usable encrypted
-- checkpoint are separate external facts.
data CheckpointObservation snapshot
  = CheckpointMissing
  | CheckpointValid !snapshot
  | CheckpointCorrupt !CheckpointFailure
  | CheckpointUnobservable !ObservationFailure
  deriving (Eq, Show)

-- | Source-of-truth status for one Pulumi-managed AWS stack.
data ResidueStatus
  = ResidueAbsent
  | ResiduePresent !ResidueDetails
  | ResidueUnreachable !ResidueUnreachableReason
  deriving (Eq, Show)

-- | Sprint 4.81: which authority answered a residue question.
--
-- [chaos_hardening_doctrine.md § 24](../../../documents/engineering/chaos_hardening_doctrine.md)
-- requires that a derived value be enforced at the layer its source object is
-- authoritative for, and that a derivation name the layer whenever it names the
-- source. A 'ResidueStatus' alone names neither: 'ResidueAbsent' minted from a
-- retained checkpoint and 'ResidueAbsent' minted from AWS are the same value,
-- and the per-run cascade consumed the first as though it were the second.
--
-- This is a flat exhaustive ADT carried as a __field__, never a type index on
-- the observed value — § 21's carried-over prohibition names @residue@
-- explicitly.
data ResidueObservationLayer
  = -- | The retained Lifecycle Authority checkpoint store. Authoritative for
    -- /what checkpoints this cluster holds/, and for nothing else.
    ResidueLayerRetainedCheckpoint
  | -- | AWS itself, through a tagged-resource or service query. Authoritative
    -- for /what resources exist/.
    ResidueLayerAwsResource
  | -- | The Vault seal/permission gate, which decides whether the checkpoint
    -- layer is consultable at all. Never an answer about resources.
    ResidueLayerVaultGate
  | -- | A test-only harness bypass. Present so a bypassed answer can never be
    -- mistaken for an observed one.
    ResidueLayerHarnessBypass
  deriving (Eq, Show, Bounded, Enum)

renderResidueObservationLayer :: ResidueObservationLayer -> String
renderResidueObservationLayer layer = case layer of
  ResidueLayerRetainedCheckpoint -> "retained checkpoint store"
  ResidueLayerAwsResource -> "AWS"
  ResidueLayerVaultGate -> "Vault gate"
  ResidueLayerHarnessBypass -> "harness bypass"

-- | Sprint 4.81: a residue answer bound to the authority that produced it.
--
-- The constructor is __not exported__. 'observeResidueAt' is the sole minter,
-- and @checkResidueObservationMinter@ in @Prodbox.CheckCode@ restricts its
-- callers to the observing modules — § 21's class-A move, in the same idiom as
-- the Sprint @1.76@ @RoundTripWitness@ and Sprint @4.58@ @TargetSinkVersion@
-- boundaries. A consumer therefore cannot obtain an answer without also
-- obtaining the layer it was answered at.
data ResidueObservation = ResidueObservation
  { internalObservationLayer :: !ResidueObservationLayer
  , internalObservationStatus :: !ResidueStatus
  }
  deriving (Eq, Show)

-- | The sole minter. Takes the layer first so a call site reads as a claim
-- about an authority rather than as a wrapper around a status.
observeResidueAt :: ResidueObservationLayer -> ResidueStatus -> ResidueObservation
observeResidueAt layer status =
  ResidueObservation
    { internalObservationLayer = layer
    , internalObservationStatus = status
    }

residueObservationLayer :: ResidueObservation -> ResidueObservationLayer
residueObservationLayer = internalObservationLayer

residueObservationStatus :: ResidueObservation -> ResidueStatus
residueObservationStatus = internalObservationStatus

-- | Refine an answer without changing the authority that gave it. Used where a
-- gate downgrades an observation it did not itself make; the layer is carried
-- through rather than re-asserted, so a refinement cannot silently relabel
-- which authority spoke.
mapResidueObservationStatus
  :: (ResidueStatus -> ResidueStatus) -> ResidueObservation -> ResidueObservation
mapResidueObservationStatus f observation =
  observation {internalObservationStatus = f (internalObservationStatus observation)}

-- | Sprint 4.82: what AWS said when it was consulted as the second layer.
--
-- Kept separate from 'ResidueStatus' because it answers a different question.
-- 'ResidueStatus' is /what does the authority that was asked report/;
-- this is /what resources exist/, which only AWS can answer.
data AwsLayerAnswer
  = -- | AWS was queried and reported no matching resources. A positive
    -- observation of absence at the layer the question is consumed at.
    AwsLayerNoResources
  | -- | AWS was queried and reported resources. The payload is the operator-
    -- visible evidence (ARNs), not a count.
    AwsLayerResourcesPresent ![String]
  | -- | AWS was queried and could not answer.
    AwsLayerUnobservable !String
  | -- | AWS was not consulted — no admin credential, or the authority layer
    -- already answered so no second query was needed. Never an absence.
    AwsLayerNotConsulted !String
  deriving (Eq, Show)

-- | Sprint 4.82: the resolved answer, carrying which layer resolved it.
--
-- This is the value the cascade consumes. It exists so that "the resources are
-- gone" and "the checkpoint store said so" cannot be the same claim, and so a
-- narration can name the confirming authority rather than asserting a bare
-- absence.
data ResidueResolution
  = -- | The asked authority answered, and its answer stands on its own.
    ResolutionAuthorityObserved !ResidueObservationLayer !ResidueStatus
  | -- | The authority was unreachable and AWS positively reported no
    -- resources. The consumed question is answered at the layer that owns it.
    ResolutionAwsLayerAbsent
  | -- | The authority was unreachable and AWS reported resources. A Pulumi
    -- destroy is impossible without the checkpoint, so this is a hard failure
    -- and not a licence to proceed.
    ResolutionAwsLayerPresent ![String]
  | -- | Neither layer could answer. Fail closed, exactly as before Sprint 4.82.
    ResolutionBothLayersUnobservable !ResidueUnreachableReason !AwsLayerAnswer
  deriving (Eq, Show)

-- | Sprint 4.82: total over @(observation × AWS answer)@.
--
-- The AWS layer is consulted only where the asked authority failed to answer;
-- a positive observation at the authority layer is never overridden by AWS,
-- because the two answer different questions and the authority's answer is
-- authoritative for the one it was asked.
resolveResidueAcrossLayers
  :: ResidueObservation -> AwsLayerAnswer -> ResidueResolution
resolveResidueAcrossLayers observation awsAnswer =
  case residueObservationStatus observation of
    ResidueAbsent -> observed ResidueAbsent
    ResiduePresent details -> observed (ResiduePresent details)
    ResidueUnreachable reason -> case awsAnswer of
      AwsLayerNoResources -> ResolutionAwsLayerAbsent
      AwsLayerResourcesPresent arns -> ResolutionAwsLayerPresent arns
      unobservable -> ResolutionBothLayersUnobservable reason unobservable
 where
  observed = ResolutionAuthorityObserved (residueObservationLayer observation)

-- | The status a status-shaped consumer (the destroy fold) should see.
--
-- 'ResolutionAwsLayerPresent' deliberately maps to 'ResidueUnreachable' rather
-- than to 'ResiduePresent': AWS proves the resources exist, but the checkpoint
-- needed to destroy them through Pulumi is unreadable, so presenting this as a
-- destroyable presence would promise an action the cascade cannot take.
residueResolutionStatus :: ResidueResolution -> ResidueStatus
residueResolutionStatus resolution = case resolution of
  ResolutionAuthorityObserved _ status -> status
  ResolutionAwsLayerAbsent -> ResidueAbsent
  ResolutionAwsLayerPresent arns ->
    ResidueUnreachable
      ( ResidueQueryFailed
          ( "AWS reports "
              ++ show (length arns)
              ++ " live resource(s) but the retained checkpoint is unreadable, "
              ++ "so no Pulumi destroy can be submitted for them"
          )
      )
  ResolutionBothLayersUnobservable reason _ -> ResidueUnreachable reason

-- | Whether this resolution positively establishes absence, and at which layer.
--
-- Only the two positive arms qualify. An unobservable pair never does, which is
-- the Sprint 4.19 rule carried across the new layer.
residueResolutionConfirmedAbsence :: ResidueResolution -> Maybe ResidueObservationLayer
residueResolutionConfirmedAbsence resolution = case resolution of
  ResolutionAuthorityObserved layer ResidueAbsent -> Just layer
  ResolutionAuthorityObserved _ _ -> Nothing
  ResolutionAwsLayerAbsent -> Just ResidueLayerAwsResource
  ResolutionAwsLayerPresent _ -> Nothing
  ResolutionBothLayersUnobservable _ _ -> Nothing

renderResidueResolution :: ResidueResolution -> String
renderResidueResolution resolution = case resolution of
  ResolutionAuthorityObserved layer status ->
    renderResidueStatus status ++ " [answered by: " ++ renderResidueObservationLayer layer ++ "]"
  ResolutionAwsLayerAbsent ->
    "absent [answered by: "
      ++ renderResidueObservationLayer ResidueLayerAwsResource
      ++ "; the retained checkpoint was unreadable, so AWS was consulted as the "
      ++ "authority for whether the resources exist]"
  ResolutionAwsLayerPresent arns ->
    "present at AWS but not destroyable ["
      ++ show (length arns)
      ++ " resource(s); the retained checkpoint is unreadable so no Pulumi destroy can run]"
  ResolutionBothLayersUnobservable reason awsAnswer ->
    "NOT OBSERVED at either layer (retained checkpoint: "
      ++ renderResidueUnreachableReason reason
      ++ "; AWS: "
      ++ renderAwsLayerAnswer awsAnswer
      ++ ")"

renderAwsLayerAnswer :: AwsLayerAnswer -> String
renderAwsLayerAnswer answer = case answer of
  AwsLayerNoResources -> "no matching resources"
  AwsLayerResourcesPresent arns -> show (length arns) ++ " resource(s) present"
  AwsLayerUnobservable detail -> "could not be queried: " ++ detail
  AwsLayerNotConsulted reason -> "not consulted (" ++ reason ++ ")"

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
    --
    -- Sprint 4.81: this names a boundary that was actually dialled. It is no
    -- longer the label for an authentication failure that never reached MinIO
    -- — see 'ResidueAuthorityUnauthenticated'.
    ResidueBackendMinioUnreachable !String
  | -- | Sprint 4.81: the caller could not authenticate to the Lifecycle
    -- Authority, so no backend was contacted at all.
    --
    -- Before this sprint every 'Prodbox.ControlPlane.LifecycleAuthorityAuthentication'
    -- failure — absent kubeconfig, unobservable external-caller ServiceAccount,
    -- refused self-TokenRequest RBAC, refused TokenRequest, failed Vault
    -- Kubernetes login, unavailable Transit signing capability — was folded
    -- into 'ResidueBackendMinioUnreachable', and a live cascade run printed
    -- @MinIO backend unreachable@ about a MinIO that was never dialled while
    -- naming three healthy subsystems and not the one that failed. Conversion
    -- class, [chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md).
    ResidueAuthorityUnauthenticated !String
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
  ResidueAuthorityUnauthenticated msg ->
    "Lifecycle Authority could not be authenticated, so no state backend was contacted: " ++ msg
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
--
-- Sprint 4.76 expresses it as @not . isResidueAbsent@ rather than as
-- @present || unreachable@. The two agree on today's three constructors
-- and disagree about a fourth: the disjunction defaults an added
-- constructor to the destructive side (does not block), while this form
-- defaults it to blocking. Only a positive observation of absence
-- releases the gate, which is the invariant the disjunction was
-- enumerating.
residueBlocksTeardownGate :: ResidueStatus -> Bool
residueBlocksTeardownGate = not . isResidueAbsent
