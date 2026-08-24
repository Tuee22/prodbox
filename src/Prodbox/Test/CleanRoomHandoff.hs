{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module Prodbox.Test.CleanRoomHandoff
  ( CleanRoomAction (..)
  , CleanRoomPrefixRefusal (..)
  , RollbackDisposition (..)
  , CutoverPhase (..)
  , CutoverState
  , QualificationPassed
  , CutoverRefusal (..)
  , initialCutoverState
  , qualifyReplacement
  , rollbackLegacy
  , activateReplacement
  , deleteLegacyRoute
  , qualifyPostActivation
  , cutoverStatePhase
  , cutoverStateHasLegacyWriter
  , cutoverStateHasReplacementWriter
  , CutoverPlanStage (..)
  , canonicalCutoverPlan
  , resumeCutoverPlan
  , LegacyScanMode (..)
  , LegacyCutoverResidue (..)
  , registeredLegacyCutoverFragments
  , legacyCutoverResidueViolations
  , InstalledCascadeFault (..)
  , InstalledCascadeDisposition (..)
  , InstalledCascadeTrace (..)
  , fixedInstalledCascadeTraces
  , renderInstalledCascadeTrace
  , ReplacementCascadeBoundary (..)
  , canonicalReplacementCascadeBoundaries
  , resumeReplacementCascadeBoundaries
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

import Data.List (isInfixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.Model (registeredResourceKeyText)
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneFinalDisposition (..)
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( SomeManagedResourceDescriptor (..)
  , managedResourceKey
  , managedResourceRegistry
  )
import Prodbox.Test.Qualification.Evidence
  ( QualificationEvidence
  , QualificationIdentity
  , qualificationEvidenceReplacementIdentity
  )

-- Typed single-writer cutover ------------------------------------------------

data CutoverPhase
  = PreActivation
  | PostActivation
  | LegacyRouteDeleted
  | PostActivationQualified
  deriving (Eq, Show)

data LegacyWriterPermit = LegacyWriterPermit
  deriving (Show)

data ReplacementWriterPermit = ReplacementWriterPermit
  deriving (Show)

-- | Evidence that the complete Standard-P validator accepted one exact
-- replacement identity.  Its constructor is private; the only producer
-- consumes an already-validated 'QualificationEvidence'.
data QualificationPassed = QualificationPassed !QualificationIdentity
  deriving (Eq, Show)

-- | At most one mutation permit exists in every phase.  Activation consumes
-- the legacy permit; deletion cannot recreate it; and the identity-changing
-- deletion returns the state to qualification-pending.
data CutoverState (phase :: CutoverPhase) where
  CutoverPreActivation
    :: !QualificationIdentity
    -> !LegacyWriterPermit
    -> CutoverState 'PreActivation
  CutoverPostActivation
    :: !QualificationIdentity
    -> !ReplacementWriterPermit
    -> CutoverState 'PostActivation
  CutoverLegacyRouteDeleted
    :: !QualificationIdentity
    -> !ReplacementWriterPermit
    -> CutoverState 'LegacyRouteDeleted
  CutoverPostActivationQualified
    :: !QualificationIdentity
    -> !ReplacementWriterPermit
    -> CutoverState 'PostActivationQualified

deriving instance Show (CutoverState phase)

data CutoverRefusal
  = CutoverQualificationIdentityMismatch
  deriving (Eq, Show)

initialCutoverState
  :: QualificationIdentity -> CutoverState 'PreActivation
initialCutoverState identity =
  CutoverPreActivation identity LegacyWriterPermit

qualifyReplacement
  :: QualificationIdentity
  -> QualificationEvidence
  -> Either CutoverRefusal QualificationPassed
qualifyReplacement expected evidence
  | qualificationEvidenceReplacementIdentity evidence == expected =
      Right (QualificationPassed expected)
  | otherwise = Left CutoverQualificationIdentityMismatch

-- | The sole rollback operation is indexed to pre-activation.  There is no
-- function accepting a post-activation state.
rollbackLegacy
  :: CutoverState 'PreActivation -> CutoverState 'PreActivation
rollbackLegacy = id

activateReplacement
  :: QualificationPassed
  -> CutoverState 'PreActivation
  -> Either CutoverRefusal (CutoverState 'PostActivation)
activateReplacement (QualificationPassed qualified) state = case state of
  CutoverPreActivation expected LegacyWriterPermit
    | qualified == expected ->
        Right (CutoverPostActivation expected ReplacementWriterPermit)
    | otherwise -> Left CutoverQualificationIdentityMismatch

-- | Deleting the legacy source changes the source identity.  The replacement
-- remains the only writer, but the resulting deployment is deliberately not
-- called qualified until a new exact artifact is consumed below.
deleteLegacyRoute
  :: QualificationIdentity
  -> CutoverState 'PostActivation
  -> CutoverState 'LegacyRouteDeleted
deleteLegacyRoute resultingIdentity state = case state of
  CutoverPostActivation _ ReplacementWriterPermit ->
    CutoverLegacyRouteDeleted resultingIdentity ReplacementWriterPermit

qualifyPostActivation
  :: QualificationPassed
  -> CutoverState 'LegacyRouteDeleted
  -> Either CutoverRefusal (CutoverState 'PostActivationQualified)
qualifyPostActivation (QualificationPassed qualified) state = case state of
  CutoverLegacyRouteDeleted expected ReplacementWriterPermit
    | qualified == expected ->
        Right
          (CutoverPostActivationQualified expected ReplacementWriterPermit)
    | otherwise -> Left CutoverQualificationIdentityMismatch

cutoverStatePhase :: CutoverState phase -> CutoverPhase
cutoverStatePhase state = case state of
  CutoverPreActivation {} -> PreActivation
  CutoverPostActivation {} -> PostActivation
  CutoverLegacyRouteDeleted {} -> LegacyRouteDeleted
  CutoverPostActivationQualified {} -> PostActivationQualified

cutoverStateHasLegacyWriter :: CutoverState phase -> Bool
cutoverStateHasLegacyWriter state = case state of
  CutoverPreActivation {} -> True
  CutoverPostActivation {} -> False
  CutoverLegacyRouteDeleted {} -> False
  CutoverPostActivationQualified {} -> False

cutoverStateHasReplacementWriter :: CutoverState phase -> Bool
cutoverStateHasReplacementWriter state = case state of
  CutoverPreActivation {} -> False
  CutoverPostActivation {} -> True
  CutoverLegacyRouteDeleted {} -> True
  CutoverPostActivationQualified {} -> True

-- Staged Plan / Apply ordering ----------------------------------------------

data CutoverPlanStage
  = PlanRunQualificationOnlyCandidate
  | PlanObserveQualificationReceipt
  | PlanActivateSingleReplacementWriter
  | PlanDeleteLegacyRouteAndIdentity
  | PlanRunPostActivationQualification
  | PlanObservePostActivationQualificationReceipt
  deriving (Bounded, Enum, Eq, Ord, Show)

canonicalCutoverPlan :: [CutoverPlanStage]
canonicalCutoverPlan = [minBound .. maxBound]

resumeCutoverPlan
  :: [CutoverPlanStage]
  -> Either (CutoverPlanStage, Maybe CutoverPlanStage) [CutoverPlanStage]
resumeCutoverPlan completed = go canonicalCutoverPlan completed
 where
  go remaining [] = Right remaining
  go [] (observed : _) = Left (observed, Nothing)
  go (expected : remaining) (observed : observations)
    | observed == expected = go remaining observations
    | otherwise = Left (observed, Just expected)

-- Bounded pre/post activation legacy scanner --------------------------------

data LegacyScanMode
  = LegacyScanPreActivation
  | LegacyScanPostActivation
  deriving (Eq, Show)

data LegacyCutoverResidue
  = LegacyCutoverFragmentMissing !Text
  | LegacyCutoverFragmentDuplicated !Text !Int
  | LegacyCutoverFragmentUnexpected !FilePath !Text
  | LegacyCutoverFragmentSurvived !FilePath !Text
  deriving (Eq, Ord, Show)

-- | The exact legacy writer/executor set admitted before activation.  This is
-- bounded: a new matching site fails the pre-activation scan instead of being
-- silently grandfathered.
registeredLegacyCutoverFragments :: [(FilePath, Text)]
registeredLegacyCutoverFragments =
  [ ("src/Prodbox/CLI/Rke2.hs", "runNativeDeleteCascade")
  , ("src/Prodbox/Legacy/EscapeRegistry.hs", "runNativeDeleteCascade")
  , ("src/Prodbox/Lifecycle/ResourceRegistry.hs", "runNativeDeleteCascade")
  , ("src/Prodbox/CLI/Rke2.hs", "runAuthorizedDeleteCascade")
  , ("src/Prodbox/CLI/Rke2.hs", "queryAwsLayerForPerRun")
  , ("src/Prodbox/CLI/Rke2.hs", "inferCascadeSubstrate")
  , ("src/Prodbox/CLI/Rke2.hs", "CascadePhaseOutcome")
  ]

legacyCutoverResidueViolations
  :: LegacyScanMode
  -> [(FilePath, Text)]
  -> [LegacyCutoverResidue]
legacyCutoverResidueViolations mode sources = case mode of
  LegacyScanPreActivation -> concatMap validateRegistered registeredFragments
  LegacyScanPostActivation ->
    [ LegacyCutoverFragmentSurvived path fragment
    | (path, source) <- sources
    , fragment <- registeredFragments
    , fragment `Text.isInfixOf` source
    ]
 where
  registeredFragments = nub (map snd registeredLegacyCutoverFragments)
  occurrences fragment =
    [ path
    | (path, source) <- sources
    , fragment `Text.isInfixOf` source
    ]
  validateRegistered fragment
    | actual == expected = []
    | null actual = [LegacyCutoverFragmentMissing fragment]
    | not (null unexpected) =
        [ LegacyCutoverFragmentUnexpected path fragment
        | path <- unexpected
        ]
    | otherwise = [LegacyCutoverFragmentDuplicated fragment (length actual)]
   where
    actual = sort (occurrences fragment)
    expected =
      sort
        [ path
        | (path, registered) <- registeredLegacyCutoverFragments
        , registered == fragment
        ]
    unexpected = filter (`notElem` expected) actual

-- Installed cascade traces --------------------------------------------------

data InstalledCascadeFault
  = InstalledCascadeSuccess
  | InstalledCascadeEffectFailure
  | InstalledCascadeCancellation
  | InstalledCascadeResponseLoss
  | InstalledCascadeRestart
  deriving (Bounded, Enum, Eq, Ord, Show)

data InstalledCascadeDisposition
  = InstalledCascadeComplete
  | InstalledCascadeIncomplete
  deriving (Eq, Ord, Show)

data InstalledCascadeTrace = InstalledCascadeTrace
  { installedTraceFault :: !InstalledCascadeFault
  , installedTraceRunId :: !Text
  , installedTraceResourceKeys :: ![Text]
  , installedTraceObservationAuthorities :: ![Text]
  , installedTraceRecoveryDisposition :: !RecoveryPlaneFinalDisposition
  , installedTraceDisposition :: !InstalledCascadeDisposition
  }
  deriving (Eq, Show)

fixedInstalledCascadeTraces :: [InstalledCascadeTrace]
fixedInstalledCascadeTraces = map traceFor [minBound .. maxBound]
 where
  traceFor fault =
    InstalledCascadeTrace
      { installedTraceFault = fault
      , installedTraceRunId = "cascade-candidate-regression"
      , installedTraceResourceKeys = resourceKeys
      , installedTraceObservationAuthorities =
          [ "lifecycle-authority"
          , "provider-worker"
          , "authority-backup-adapter"
          , "local-host-read-back"
          ]
      , installedTraceRecoveryDisposition = recoveryFor fault
      , installedTraceDisposition = dispositionFor fault
      }
  resourceKeys =
    sort
      [ registeredResourceKeyText (managedResourceKey descriptor)
      | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
      ]
  recoveryFor fault = case fault of
    InstalledCascadeSuccess -> RecoveryPlaneEstablished
    InstalledCascadeEffectFailure -> RecoveryPlaneEstablished
    InstalledCascadeCancellation -> RecoveryPlaneNotEstablished
    InstalledCascadeResponseLoss -> RecoveryPlaneEstablished
    InstalledCascadeRestart -> RecoveryPlaneEstablished
  dispositionFor fault = case fault of
    InstalledCascadeEffectFailure -> InstalledCascadeIncomplete
    InstalledCascadeCancellation -> InstalledCascadeIncomplete
    _ -> InstalledCascadeComplete

renderInstalledCascadeTrace :: InstalledCascadeTrace -> String
renderInstalledCascadeTrace trace =
  unlines
    [ "INSTALLED_CASCADE_FAKE_TRACE"
    , "FAULT=" ++ show (installedTraceFault trace)
    , "CLEANUP_RUN_ID=" ++ Text.unpack (installedTraceRunId trace)
    , "RESOURCE_KEYS=" ++ show (installedTraceResourceKeys trace)
    , "OBSERVATION_AUTHORITIES=" ++ show (installedTraceObservationAuthorities trace)
    , "RECOVERY_PLANE_DISPOSITION=" ++ show (installedTraceRecoveryDisposition trace)
    , "CASCADE_DISPOSITION=" ++ show (installedTraceDisposition trace)
    ]

-- | Every durable boundary from recovery establishment through the matching
-- local-completion read-back.  The list is deliberately more precise than the
-- operator-facing clean-room actions: interruption tests resume these
-- boundaries, while the plan renders the larger workflow around them.
data ReplacementCascadeBoundary
  = StartRecoveryProfile
  | ReadBackRecoveryProfile
  | ObserveRegisteredTargets
  | CommitEksDrainIntent
  | ReadBackEksDrainIntent
  | RunEksDrainAndBackstops
  | ReconcileProviderDesiredAbsence
  | ReadBackProviderAbsence
  | AuditCascadeEscapesExactly
  | CommitPreUninstallReport
  | ReadBackPreUninstallReport
  | ArmOneShotLocalCompletionPermit
  | UninstallLocalFoundationLast
  | ReadBackLocalFoundationAbsence
  | CommitLocalCompletionReceipt
  | ReadBackLocalCompletionReceipt
  deriving (Bounded, Enum, Eq, Ord, Show)

canonicalReplacementCascadeBoundaries :: [ReplacementCascadeBoundary]
canonicalReplacementCascadeBoundaries = [minBound .. maxBound]

resumeReplacementCascadeBoundaries
  :: [ReplacementCascadeBoundary]
  -> Either
       (ReplacementCascadeBoundary, Maybe ReplacementCascadeBoundary)
       [ReplacementCascadeBoundary]
resumeReplacementCascadeBoundaries completed =
  go canonicalReplacementCascadeBoundaries completed
 where
  go remaining [] = Right remaining
  go [] (observed : _) = Left (observed, Nothing)
  go (expected : remaining) (observed : observations)
    | observed == expected = go remaining observations
    | otherwise = Left (observed, Just expected)

-- | The versioned, installed-binary clean-room contract. Each constructor is
-- an observable boundary at which interruption and restart must be safe.
data CleanRoomAction
  = ObserveLegacyRetainedState
  | ImportAuthorityProjections
  | VerifyAuthorityShadow
  | RunQualificationOnlyCascadeCandidate
  | ObserveCandidateQualificationReceipt
  | FreezeLegacyWriter
  | ActivateReplacementEpoch
  | DeleteLegacyCascadeRoute
  | RunPostActivationQualification
  | ObservePostActivationQualificationReceipt
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
      , "SCHEMA_VERSION=2"
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
  RunQualificationOnlyCascadeCandidate -> "run-qualification-only-cascade-candidate"
  ObserveCandidateQualificationReceipt -> "observe-candidate-qualification-receipt"
  FreezeLegacyWriter -> "freeze-legacy-writer"
  ActivateReplacementEpoch -> "activate-replacement-epoch"
  DeleteLegacyCascadeRoute -> "delete-legacy-cascade-route"
  RunPostActivationQualification -> "run-post-activation-qualification"
  ObservePostActivationQualificationReceipt ->
    "observe-post-activation-qualification-receipt"
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
