{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Closed desired-absence programs compiled only from the lifecycle
-- registry.  This module contains no effects or command text: it names the
-- operations and their dependency semantics so plan rendering, durable
-- execution, and reporting can consume the same topology.
module Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , registeredTargetKey
  , registeredTargetLifecycleClass
  , registeredTargetKind
  , registeredTargetCoordinateDigest
  , registeredTargetRecoveryCapabilities
  , RecoverySurfaceWitness (..)
  , TeardownOperation (..)
  , teardownOperationTag
  , ProgramNodeName (..)
  , ProgramDependency (..)
  , ProgramNode
  , DesiredAbsenceProgram
  , desiredAbsenceProgramSurface
  , desiredAbsenceProgramNodes
  , programNodeName
  , programNodeOperation
  , programNodeDependencies
  , programNodeRecoveryCapabilities
  , DesiredAbsenceProgramError (..)
  , compileDesiredAbsenceProgram
  )
where

import Data.List (partition)
import Data.Text (Text)
import Prodbox.Lifecycle.CleanupRun (CleanupDependencyKind (..))
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.RecoveryCapability
  ( RecoveryCapabilitySet
  , mergeRecoveryCapabilitySets
  , noAdditionalRecoveryCapabilities
  , resumeOrdinaryCleanupCapabilities
  )
import Prodbox.Lifecycle.Teardown.Registry

-- | The immutable registry facts an operation is allowed to retain.  There
-- is deliberately no provider response or runtime tag field here.
data RegisteredTargetBinding = RegisteredTargetBinding
  { registeredTargetKey :: !RegisteredResourceKey
  , registeredTargetLifecycleClass :: !(Maybe LifecycleClass)
  , registeredTargetKind :: !ResourceKind
  , registeredTargetCoordinateDigest :: !ManagedResourceCoordinateDigest
  , registeredTargetRecoveryCapabilities :: !RecoveryCapabilitySet
  }
  deriving (Eq, Show)

-- | Only these ordinary surfaces may establish a recovery plane.  Local-only
-- uninstall and total decommission have intentionally different authorities.
data RecoverySurfaceWitness (surface :: CleanupSurface) where
  CascadeRecoverySurface :: RecoverySurfaceWitness 'Cascade
  ExplicitPerRunRecoverySurface :: RecoverySurfaceWitness 'ExplicitPerRun
  OperationalRecoverySurface :: RecoverySurfaceWitness 'OperationalTeardown
  ExplicitLongLivedRecoverySurface :: RecoverySurfaceWitness 'ExplicitLongLived

deriving instance Eq (RecoverySurfaceWitness surface)
deriving instance Show (RecoverySurfaceWitness surface)

-- | Closed, surface-indexed lifecycle operations.  Effects and mandatory
-- read-backs are different constructors and therefore receive different
-- stable operation references in the durable lowering.
data TeardownOperation (surface :: CleanupSurface) where
  EstablishRecoveryPlane
    :: RecoverySurfaceWitness surface
    -> TeardownOperation surface
  ReadBackRecoveryPlane
    :: RecoverySurfaceWitness surface
    -> TeardownOperation surface
  ObserveRecoveryPlaneDisposition
    :: RecoverySurfaceWitness surface
    -> TeardownOperation surface
  ObserveRegisteredTarget
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ObserveStackCheckpointPair
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReconcileStackCheckpointRestore
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReadBackStackCheckpointRecovery
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  CommitAwsStackReaderBundle
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReadBackAwsStackReaderBundle
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  CommitEksDrainIntent
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReadBackEksDrainIntent
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  DrainEksKubernetesResources
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReadBackEksKubernetesDrain
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReconcileRegisteredTargetAbsent
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReadBackRegisteredTargetAbsent
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  RetireStackCheckpointPair
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  ReadBackStackCheckpointRetirement
    :: RegisteredTargetBinding
    -> TeardownOperation surface
  AuditCascadeEscapes :: TeardownOperation 'Cascade
  CommitCascadePreUninstallReport :: TeardownOperation 'Cascade
  ReadBackCascadePreUninstallReport :: TeardownOperation 'Cascade
  UninstallCascadeLocalFoundation :: TeardownOperation 'Cascade
  ReadBackCascadeLocalAbsence :: TeardownOperation 'Cascade
  CommitCascadeCompletion :: TeardownOperation 'Cascade
  ReadBackCascadeCompletion :: TeardownOperation 'Cascade
  UninstallLocalOnlyFoundation :: TeardownOperation 'LocalOnly
  ReadBackLocalOnlyAbsence :: TeardownOperation 'LocalOnly
  CommitLocalOnlyCompletion :: TeardownOperation 'LocalOnly
  ReadBackLocalOnlyCompletion :: TeardownOperation 'LocalOnly
  CommitOrdinarySurfaceReport :: TeardownOperation surface
  ReadBackOrdinarySurfaceReport :: TeardownOperation surface
  AuditTotalDecommissionEscapes :: TeardownOperation 'TotalDecommission
  ObserveExternalDecommissionReceipt :: TeardownOperation 'TotalDecommission
  UninstallDecommissionLocalFoundation :: TeardownOperation 'TotalDecommission
  ReadBackDecommissionLocalAbsence :: TeardownOperation 'TotalDecommission
  ApplyDecommissionLocalDataDisposition :: TeardownOperation 'TotalDecommission
  ReadBackDecommissionLocalDataDisposition :: TeardownOperation 'TotalDecommission
  CommitDecommissionTerminalReceipt :: TeardownOperation 'TotalDecommission
  ReadBackDecommissionTerminalReceipt :: TeardownOperation 'TotalDecommission

deriving instance Eq (TeardownOperation surface)
deriving instance Show (TeardownOperation surface)

teardownOperationTag :: TeardownOperation surface -> Text
teardownOperationTag operation = case operation of
  EstablishRecoveryPlane _ -> "establish-recovery-plane"
  ReadBackRecoveryPlane _ -> "read-back-recovery-plane"
  ObserveRecoveryPlaneDisposition _ -> "observe-recovery-plane-disposition"
  ObserveRegisteredTarget target -> targetTag "observe" target
  ObserveStackCheckpointPair target -> targetTag "observe-checkpoint-pair" target
  ReconcileStackCheckpointRestore target -> targetTag "restore-checkpoint" target
  ReadBackStackCheckpointRecovery target ->
    targetTag "read-back-checkpoint-recovery" target
  CommitAwsStackReaderBundle target ->
    targetTag "commit-aws-stack-reader-bundle" target
  ReadBackAwsStackReaderBundle target ->
    targetTag "read-back-aws-stack-reader-bundle" target
  CommitEksDrainIntent target -> targetTag "commit-eks-drain-intent" target
  ReadBackEksDrainIntent target -> targetTag "read-back-eks-drain-intent" target
  DrainEksKubernetesResources target -> targetTag "drain-eks-kubernetes" target
  ReadBackEksKubernetesDrain target -> targetTag "read-back-eks-kubernetes-drain" target
  ReconcileRegisteredTargetAbsent target -> targetTag "reconcile-absent" target
  ReadBackRegisteredTargetAbsent target -> targetTag "read-back-absent" target
  RetireStackCheckpointPair target -> targetTag "retire-checkpoint-pair" target
  ReadBackStackCheckpointRetirement target ->
    targetTag "read-back-checkpoint-retirement" target
  AuditCascadeEscapes -> "audit-cascade-escapes"
  CommitCascadePreUninstallReport -> "commit-cascade-pre-uninstall-report"
  ReadBackCascadePreUninstallReport -> "read-back-cascade-pre-uninstall-report"
  UninstallCascadeLocalFoundation -> "uninstall-cascade-local-foundation"
  ReadBackCascadeLocalAbsence -> "read-back-cascade-local-absence"
  CommitCascadeCompletion -> "commit-cascade-completion"
  ReadBackCascadeCompletion -> "read-back-cascade-completion"
  UninstallLocalOnlyFoundation -> "uninstall-local-only-foundation"
  ReadBackLocalOnlyAbsence -> "read-back-local-only-absence"
  CommitLocalOnlyCompletion -> "commit-local-only-completion"
  ReadBackLocalOnlyCompletion -> "read-back-local-only-completion"
  CommitOrdinarySurfaceReport -> "commit-ordinary-surface-report"
  ReadBackOrdinarySurfaceReport -> "read-back-ordinary-surface-report"
  AuditTotalDecommissionEscapes -> "audit-total-decommission-escapes"
  ObserveExternalDecommissionReceipt -> "observe-external-decommission-receipt"
  UninstallDecommissionLocalFoundation -> "uninstall-decommission-local-foundation"
  ReadBackDecommissionLocalAbsence -> "read-back-decommission-local-absence"
  ApplyDecommissionLocalDataDisposition -> "apply-decommission-local-data-disposition"
  ReadBackDecommissionLocalDataDisposition -> "read-back-decommission-local-data-disposition"
  CommitDecommissionTerminalReceipt -> "commit-decommission-terminal-receipt"
  ReadBackDecommissionTerminalReceipt -> "read-back-decommission-terminal-receipt"
 where
  targetTag prefix target =
    prefix <> "/" <> registeredResourceKeyText (registeredTargetKey target)

newtype ProgramNodeName = ProgramNodeName
  { programNodeNameText :: Text
  }
  deriving (Eq, Ord, Show)

data ProgramDependency = ProgramDependency
  { programDependencyNode :: !ProgramNodeName
  , programDependencyKind :: !CleanupDependencyKind
  }
  deriving (Eq, Show)

data ProgramNode surface = ProgramNode
  { internalProgramNodeName :: !ProgramNodeName
  , internalProgramNodeOperation :: !(TeardownOperation surface)
  , internalProgramNodeDependencies :: ![ProgramDependency]
  , internalProgramNodeRecoveryCapabilities :: !RecoveryCapabilitySet
  }

deriving instance Eq (ProgramNode surface)
deriving instance Show (ProgramNode surface)

data DesiredAbsenceProgram surface = DesiredAbsenceProgram
  { internalDesiredAbsenceProgramSurface :: !(CleanupSurfaceWitness surface)
  , internalDesiredAbsenceProgramNodes :: ![ProgramNode surface]
  }

desiredAbsenceProgramSurface
  :: DesiredAbsenceProgram surface -> CleanupSurfaceWitness surface
desiredAbsenceProgramSurface = internalDesiredAbsenceProgramSurface

desiredAbsenceProgramNodes :: DesiredAbsenceProgram surface -> [ProgramNode surface]
desiredAbsenceProgramNodes = internalDesiredAbsenceProgramNodes

programNodeName :: ProgramNode surface -> ProgramNodeName
programNodeName = internalProgramNodeName

programNodeOperation :: ProgramNode surface -> TeardownOperation surface
programNodeOperation = internalProgramNodeOperation

programNodeDependencies :: ProgramNode surface -> [ProgramDependency]
programNodeDependencies = internalProgramNodeDependencies

programNodeRecoveryCapabilities
  :: ProgramNode surface -> RecoveryCapabilitySet
programNodeRecoveryCapabilities = internalProgramNodeRecoveryCapabilities

data DesiredAbsenceProgramError
  = DesiredAbsenceRegistryInvalid !RegistryValidationError
  | DesiredAbsenceLocalTargetMissing !CleanupSurface
  | DesiredAbsenceLocalTargetDuplicated !CleanupSurface
  deriving (Eq, Show)

compileDesiredAbsenceProgram
  :: CleanupSurfaceWitness surface
  -> Either DesiredAbsenceProgramError (DesiredAbsenceProgram surface)
compileDesiredAbsenceProgram surface = do
  either (Left . DesiredAbsenceRegistryInvalid) Right lifecycleRegistryValidation
  let targets = cleanupTargetsForSurface surface
      (localTargets, managedTargets) =
        partition ((== LocalSubstrate) . cleanupTargetKind) targets
      managedBindings = map targetBinding managedTargets
  nodes <- case surface of
    LocalOnlySurface -> do
      requireOneLocal LocalOnly localTargets
      pure localOnlyNodes
    CascadeSurface -> do
      requireOneLocal Cascade localTargets
      pure (cascadeNodes managedBindings)
    ExplicitPerRunSurface ->
      pure (ordinaryNodes ExplicitPerRunRecoverySurface managedBindings)
    OperationalTeardownSurface ->
      pure (ordinaryNodes OperationalRecoverySurface managedBindings)
    ExplicitLongLivedSurface ->
      pure (ordinaryNodes ExplicitLongLivedRecoverySurface managedBindings)
    TotalDecommissionSurface -> do
      requireOneLocal TotalDecommission localTargets
      pure (totalDecommissionNodes managedBindings)
  pure
    DesiredAbsenceProgram
      { internalDesiredAbsenceProgramSurface = surface
      , internalDesiredAbsenceProgramNodes = nodes
      }
 where
  requireOneLocal cleanupSurface localTargets = case localTargets of
    [] -> Left (DesiredAbsenceLocalTargetMissing cleanupSurface)
    [_] -> Right ()
    _ -> Left (DesiredAbsenceLocalTargetDuplicated cleanupSurface)

targetBinding :: CleanupTarget surface -> RegisteredTargetBinding
targetBinding target =
  RegisteredTargetBinding
    { registeredTargetKey = cleanupTargetKey target
    , registeredTargetLifecycleClass = cleanupTargetLifecycleClass target
    , registeredTargetKind = cleanupTargetKind target
    , registeredTargetCoordinateDigest = cleanupTargetCoordinateDigest target
    , registeredTargetRecoveryCapabilities =
        cleanupTargetRecoveryCapabilities target
    }

localOnlyNodes :: [ProgramNode 'LocalOnly]
localOnlyNodes =
  [ programNode "local/uninstall" UninstallLocalOnlyFoundation []
  , programNode
      "local/read-back-absence"
      ReadBackLocalOnlyAbsence
      [attempt "local/uninstall"]
  , programNode
      "local/commit-completion"
      CommitLocalOnlyCompletion
      [success "local/read-back-absence"]
  , programNode
      "local/read-back-completion"
      ReadBackLocalOnlyCompletion
      [attempt "local/commit-completion"]
  ]

cascadeNodes :: [RegisteredTargetBinding] -> [ProgramNode 'Cascade]
cascadeNodes bindings =
  recoveryNodes CascadeRecoverySurface
    ++ orderedTargetNodes bindings [success "recovery/read-back"]
    ++ [ programNode
           "recovery/observe-disposition"
           (ObserveRecoveryPlaneDisposition CascadeRecoverySurface)
           (recoveryDispositionDependencies bindings)
       , programNode
           "cascade/audit-escapes"
           AuditCascadeEscapes
           ( success "recovery/observe-disposition"
               : map (success . targetCompletionName) bindings
           )
       , programNode
           "cascade/commit-pre-uninstall-report"
           CommitCascadePreUninstallReport
           [success "cascade/audit-escapes"]
       , programNode
           "cascade/read-back-pre-uninstall-report"
           ReadBackCascadePreUninstallReport
           [attempt "cascade/commit-pre-uninstall-report"]
       , programNode
           "cascade/uninstall-local"
           UninstallCascadeLocalFoundation
           [success "cascade/read-back-pre-uninstall-report"]
       , programNode
           "cascade/read-back-local-absence"
           ReadBackCascadeLocalAbsence
           [attempt "cascade/uninstall-local"]
       , programNode
           "cascade/commit-completion"
           CommitCascadeCompletion
           [success "cascade/read-back-local-absence"]
       , programNode
           "cascade/read-back-completion"
           ReadBackCascadeCompletion
           [attempt "cascade/commit-completion"]
       ]

ordinaryNodes
  :: RecoverySurfaceWitness surface
  -> [RegisteredTargetBinding]
  -> [ProgramNode surface]
ordinaryNodes recovery bindings =
  recoveryNodes recovery
    ++ orderedTargetNodes bindings [success "recovery/read-back"]
    ++ [ programNode
           "recovery/observe-disposition"
           (ObserveRecoveryPlaneDisposition recovery)
           (recoveryDispositionDependencies bindings)
       , programNode
           "surface/commit-report"
           CommitOrdinarySurfaceReport
           reportDependencies
       , programNode
           "surface/read-back-report"
           ReadBackOrdinarySurfaceReport
           [attempt "surface/commit-report"]
       ]
 where
  reportDependencies =
    success "recovery/observe-disposition"
      : map (success . targetCompletionName) bindings

totalDecommissionNodes
  :: [RegisteredTargetBinding]
  -> [ProgramNode 'TotalDecommission]
totalDecommissionNodes bindings =
  orderedTargetNodes bindings []
    ++ [ programNode
           "decommission/audit-escapes"
           AuditTotalDecommissionEscapes
           (map (success . targetCompletionName) bindings)
       , programNode
           "decommission/observe-external-receipt"
           ObserveExternalDecommissionReceipt
           []
       , programNode
           "decommission/uninstall-local"
           UninstallDecommissionLocalFoundation
           [ success "decommission/audit-escapes"
           , success "decommission/observe-external-receipt"
           ]
       , programNode
           "decommission/read-back-local-absence"
           ReadBackDecommissionLocalAbsence
           [attempt "decommission/uninstall-local"]
       , programNode
           "decommission/apply-local-data-disposition"
           ApplyDecommissionLocalDataDisposition
           [success "decommission/read-back-local-absence"]
       , programNode
           "decommission/read-back-local-data-disposition"
           ReadBackDecommissionLocalDataDisposition
           [attempt "decommission/apply-local-data-disposition"]
       , programNode
           "decommission/commit-terminal-receipt"
           CommitDecommissionTerminalReceipt
           [success "decommission/read-back-local-data-disposition"]
       , programNode
           "decommission/read-back-terminal-receipt"
           ReadBackDecommissionTerminalReceipt
           [attempt "decommission/commit-terminal-receipt"]
       ]

recoveryNodes
  :: RecoverySurfaceWitness surface
  -> [ProgramNode surface]
recoveryNodes recovery =
  [ programNode "recovery/establish" (EstablishRecoveryPlane recovery) []
  , programNode
      "recovery/read-back"
      (ReadBackRecoveryPlane recovery)
      [attempt "recovery/establish"]
  ]

recoveryDispositionDependencies
  :: [RegisteredTargetBinding]
  -> [ProgramDependency]
recoveryDispositionDependencies bindings =
  terminal "recovery/read-back"
    : map (terminal . targetCompletionName) bindings

-- | Keep the rendered program in topological order as well as encoding the
-- dependency graph.  The EKS drain prefix must precede controller-family
-- backstops, while the EKS provider destroy tail must follow their exact
-- read-backs.  This is the one projection used by every AWS-owning surface.
orderedTargetNodes
  :: [RegisteredTargetBinding]
  -> [ProgramDependency]
  -> [ProgramNode surface]
orderedTargetNodes allTargets observationDependencies =
  concatMap initialNodes allTargets ++ concatMap finalNodes allTargets
 where
  initialNodes target
    | registeredTargetKey target == AwsEksKey =
        eksStackInitialNodes observationDependencies target
    | registeredTargetKind target == Stack =
        stackTargetNodes observationDependencies target
    | otherwise = directTargetNodes allTargets observationDependencies target
  finalNodes target
    | registeredTargetKey target == AwsEksKey =
        eksStackFinalNodes allTargets target
    | otherwise = []

directTargetNodes
  :: [RegisteredTargetBinding]
  -> [ProgramDependency]
  -> RegisteredTargetBinding
  -> [ProgramNode surface]
directTargetNodes allTargets observationDependencies target =
  [ programNode
      (targetObserveName target)
      (ObserveRegisteredTarget target)
      (observationDependencies ++ controllerBackstopDependencies allTargets target)
  , programNode
      (targetEffectName target)
      (ReconcileRegisteredTargetAbsent target)
      [success (targetObserveName target)]
  , programNode
      (targetReadBackName target)
      (ReadBackRegisteredTargetAbsent target)
      [attempt (targetEffectName target)]
  ]

stackTargetNodes
  :: [ProgramDependency]
  -> RegisteredTargetBinding
  -> [ProgramNode surface]
stackTargetNodes observationDependencies target =
  [ programNode
      (checkpointObserveName target)
      (ObserveStackCheckpointPair target)
      observationDependencies
  , programNode
      (targetObserveName target)
      (ObserveRegisteredTarget target)
      observationDependencies
  , programNode
      (checkpointRestoreName target)
      (ReconcileStackCheckpointRestore target)
      [ success (checkpointObserveName target)
      , success (targetObserveName target)
      ]
  , programNode
      (checkpointRecoveryReadBackName target)
      (ReadBackStackCheckpointRecovery target)
      [attempt (checkpointRestoreName target)]
  , programNode
      (awsStackReaderCommitName target)
      (CommitAwsStackReaderBundle target)
      [success (checkpointRecoveryReadBackName target)]
  , programNode
      (awsStackReaderReadBackName target)
      (ReadBackAwsStackReaderBundle target)
      [attempt (awsStackReaderCommitName target)]
  , programNode
      (targetEffectName target)
      (ReconcileRegisteredTargetAbsent target)
      [ success (targetObserveName target)
      , success (checkpointRecoveryReadBackName target)
      , success (awsStackReaderReadBackName target)
      ]
  , programNode
      (targetReadBackName target)
      (ReadBackRegisteredTargetAbsent target)
      [attempt (targetEffectName target)]
  , programNode
      (checkpointRetirementName target)
      (RetireStackCheckpointPair target)
      [success (targetReadBackName target)]
  , programNode
      (checkpointRetirementReadBackName target)
      (ReadBackStackCheckpointRetirement target)
      [attempt (checkpointRetirementName target)]
  ]

-- | EKS destruction has an additional write-ahead Kubernetes drain protocol.
-- The exact target inventory and cluster UID are committed and positively
-- read back before mutation.  The mutation is followed by an independent
-- read-back, and only that successful read-back can authorize stack destroy.
eksStackInitialNodes
  :: [ProgramDependency]
  -> RegisteredTargetBinding
  -> [ProgramNode surface]
eksStackInitialNodes observationDependencies target =
  [ programNode
      (checkpointObserveName target)
      (ObserveStackCheckpointPair target)
      observationDependencies
  , programNode
      (targetObserveName target)
      (ObserveRegisteredTarget target)
      observationDependencies
  , programNode
      (checkpointRestoreName target)
      (ReconcileStackCheckpointRestore target)
      [ success (checkpointObserveName target)
      , success (targetObserveName target)
      ]
  , programNode
      (checkpointRecoveryReadBackName target)
      (ReadBackStackCheckpointRecovery target)
      [attempt (checkpointRestoreName target)]
  , programNode
      (awsStackReaderCommitName target)
      (CommitAwsStackReaderBundle target)
      [success (checkpointRecoveryReadBackName target)]
  , programNode
      (awsStackReaderReadBackName target)
      (ReadBackAwsStackReaderBundle target)
      [attempt (awsStackReaderCommitName target)]
  , programNode
      (eksDrainIntentCommitName target)
      (CommitEksDrainIntent target)
      [attempt (targetObserveName target)]
  , programNode
      (eksDrainIntentReadBackName target)
      (ReadBackEksDrainIntent target)
      [attempt (eksDrainIntentCommitName target)]
  , programNode
      (eksDrainName target)
      (DrainEksKubernetesResources target)
      [attempt (eksDrainIntentReadBackName target)]
  , programNode
      (eksDrainReadBackName target)
      (ReadBackEksKubernetesDrain target)
      [attempt (eksDrainName target)]
  ]

eksStackFinalNodes
  :: [RegisteredTargetBinding]
  -> RegisteredTargetBinding
  -> [ProgramNode surface]
eksStackFinalNodes allTargets target =
  [ programNode
      (targetEffectName target)
      (ReconcileRegisteredTargetAbsent target)
      ( [ success (targetObserveName target)
        , success (checkpointRecoveryReadBackName target)
        , success (awsStackReaderReadBackName target)
        , success (eksDrainReadBackName target)
        ]
          ++ eksBackstopSuccessDependencies allTargets target
      )
  , programNode
      (targetReadBackName target)
      (ReadBackRegisteredTargetAbsent target)
      [attempt (targetEffectName target)]
  , programNode
      (checkpointRetirementName target)
      (RetireStackCheckpointPair target)
      [success (targetReadBackName target)]
  , programNode
      (checkpointRetirementReadBackName target)
      (ReadBackStackCheckpointRetirement target)
      [attempt (checkpointRetirementName target)]
  ]

-- | Controller-family backstops run after their owning stack's drain node was
-- attempted, including when that node refused or lost its response.  They are
-- not suppressed by an observation or drain failure.
--
-- The pair of keys was hand-authored on both sides of this relation until
-- Sprint @4.85@ derived it: which stack's controllers own a family is a
-- registry fact, recorded once as 'registeredOwnershipEdges' and read here
-- rather than restated.  The write-ahead ownership manifest reads the same
-- relation, so the manifest a stack may seed and the order its destroy waits
-- on cannot disagree.
controllerBackstopDependencies
  :: [RegisteredTargetBinding]
  -> RegisteredTargetBinding
  -> [ProgramDependency]
controllerBackstopDependencies allTargets target =
  [ attempt (eksDrainName ownerTarget)
  | ownerTarget <- allTargets
  , registeredTargetKey ownerTarget `elem` owningStackKeys (registeredTargetKey target)
  ]

-- | A registered stack cannot be destroyed until every controller-owned family
-- it owns — each of which can outlive it — has independently converged.
eksBackstopSuccessDependencies
  :: [RegisteredTargetBinding]
  -> RegisteredTargetBinding
  -> [ProgramDependency]
eksBackstopSuccessDependencies allTargets owner =
  [ success (targetReadBackName backstop)
  | backstop <- allTargets
  , registeredTargetKey backstop `elem` ownedFamilyKeys (registeredTargetKey owner)
  ]

owningStackKeys :: RegisteredResourceKey -> [RegisteredResourceKey]
owningStackKeys resourceKey =
  [ ownershipEdgeStackKey edge
  | edge <- registeredOwnershipEdges
  , ownershipEdgeResourceKey edge == resourceKey
  ]

ownedFamilyKeys :: RegisteredResourceKey -> [RegisteredResourceKey]
ownedFamilyKeys stackKey =
  [ ownershipEdgeResourceKey edge
  | edge <- registeredOwnershipEdges
  , ownershipEdgeStackKey edge == stackKey
  ]

eksDrainIntentCommitName :: RegisteredTargetBinding -> Text
eksDrainIntentCommitName = targetName "commit-eks-drain-intent"

eksDrainIntentReadBackName :: RegisteredTargetBinding -> Text
eksDrainIntentReadBackName = targetName "read-back-eks-drain-intent"

eksDrainName :: RegisteredTargetBinding -> Text
eksDrainName = targetName "drain-eks-kubernetes"

eksDrainReadBackName :: RegisteredTargetBinding -> Text
eksDrainReadBackName = targetName "read-back-eks-kubernetes-drain"

checkpointObserveName :: RegisteredTargetBinding -> Text
checkpointObserveName = targetName "observe-checkpoint-pair"

checkpointRestoreName :: RegisteredTargetBinding -> Text
checkpointRestoreName = targetName "restore-checkpoint"

checkpointRecoveryReadBackName :: RegisteredTargetBinding -> Text
checkpointRecoveryReadBackName = targetName "read-back-checkpoint-recovery"

awsStackReaderCommitName :: RegisteredTargetBinding -> Text
awsStackReaderCommitName = targetName "commit-aws-stack-reader-bundle"

awsStackReaderReadBackName :: RegisteredTargetBinding -> Text
awsStackReaderReadBackName = targetName "read-back-aws-stack-reader-bundle"

checkpointRetirementName :: RegisteredTargetBinding -> Text
checkpointRetirementName = targetName "retire-checkpoint-pair"

checkpointRetirementReadBackName :: RegisteredTargetBinding -> Text
checkpointRetirementReadBackName = targetName "read-back-checkpoint-retirement"

targetObserveName :: RegisteredTargetBinding -> Text
targetObserveName = targetName "observe"

targetEffectName :: RegisteredTargetBinding -> Text
targetEffectName = targetName "reconcile-absent"

targetReadBackName :: RegisteredTargetBinding -> Text
targetReadBackName = targetName "read-back-absent"

targetCompletionName :: RegisteredTargetBinding -> Text
targetCompletionName target
  | registeredTargetKind target == Stack = checkpointRetirementReadBackName target
  | otherwise = targetReadBackName target

targetName :: Text -> RegisteredTargetBinding -> Text
targetName suffix target =
  "target/" <> registeredResourceKeyText (registeredTargetKey target) <> "/" <> suffix

programNode
  :: Text
  -> TeardownOperation surface
  -> [ProgramDependency]
  -> ProgramNode surface
programNode name operation dependencies =
  ProgramNode
    { internalProgramNodeName = ProgramNodeName name
    , internalProgramNodeOperation = operation
    , internalProgramNodeDependencies = dependencies
    , internalProgramNodeRecoveryCapabilities =
        mergeRecoveryCapabilitySets
          resumeOrdinaryCleanupCapabilities
          (operationAdditionalRecoveryCapabilities operation)
    }

operationAdditionalRecoveryCapabilities
  :: TeardownOperation surface -> RecoveryCapabilitySet
operationAdditionalRecoveryCapabilities operation =
  case operationTargetBinding operation of
    Nothing -> noAdditionalRecoveryCapabilities
    Just target -> registeredTargetRecoveryCapabilities target

operationTargetBinding
  :: TeardownOperation surface -> Maybe RegisteredTargetBinding
operationTargetBinding operation = case operation of
  ObserveRegisteredTarget target -> Just target
  ObserveStackCheckpointPair target -> Just target
  ReconcileStackCheckpointRestore target -> Just target
  ReadBackStackCheckpointRecovery target -> Just target
  CommitAwsStackReaderBundle target -> Just target
  ReadBackAwsStackReaderBundle target -> Just target
  CommitEksDrainIntent target -> Just target
  ReadBackEksDrainIntent target -> Just target
  DrainEksKubernetesResources target -> Just target
  ReadBackEksKubernetesDrain target -> Just target
  ReconcileRegisteredTargetAbsent target -> Just target
  ReadBackRegisteredTargetAbsent target -> Just target
  RetireStackCheckpointPair target -> Just target
  ReadBackStackCheckpointRetirement target -> Just target
  EstablishRecoveryPlane _ -> Nothing
  ReadBackRecoveryPlane _ -> Nothing
  ObserveRecoveryPlaneDisposition _ -> Nothing
  AuditCascadeEscapes -> Nothing
  CommitCascadePreUninstallReport -> Nothing
  ReadBackCascadePreUninstallReport -> Nothing
  UninstallCascadeLocalFoundation -> Nothing
  ReadBackCascadeLocalAbsence -> Nothing
  CommitCascadeCompletion -> Nothing
  ReadBackCascadeCompletion -> Nothing
  UninstallLocalOnlyFoundation -> Nothing
  ReadBackLocalOnlyAbsence -> Nothing
  CommitLocalOnlyCompletion -> Nothing
  ReadBackLocalOnlyCompletion -> Nothing
  CommitOrdinarySurfaceReport -> Nothing
  ReadBackOrdinarySurfaceReport -> Nothing
  AuditTotalDecommissionEscapes -> Nothing
  ObserveExternalDecommissionReceipt -> Nothing
  UninstallDecommissionLocalFoundation -> Nothing
  ReadBackDecommissionLocalAbsence -> Nothing
  ApplyDecommissionLocalDataDisposition -> Nothing
  ReadBackDecommissionLocalDataDisposition -> Nothing
  CommitDecommissionTerminalReceipt -> Nothing
  ReadBackDecommissionTerminalReceipt -> Nothing

success :: Text -> ProgramDependency
success name = ProgramDependency (ProgramNodeName name) CleanupRequiresSuccess

attempt :: Text -> ProgramDependency
attempt name = ProgramDependency (ProgramNodeName name) CleanupRequiresAttempt

terminal :: Text -> ProgramDependency
terminal name = ProgramDependency (ProgramNodeName name) CleanupRequiresTerminal
