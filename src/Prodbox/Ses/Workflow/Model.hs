{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure, revision-bound SES aggregate. Decisions emit one disjoint effect
-- family at a time; interpreters cannot receive another role's constructor.
module Prodbox.Ses.Workflow.Model
  ( SesContract (..)
  , CredentialOwnership (..)
  , LegacyEvidence (..)
  , CustodyReceipt (..)
  , TargetReceipt (..)
  , SesWorkflowState (..)
  , SesWorkflowCommand (..)
  , SesWorkflowEvent (..)
  , SesWorkflowEffect (..)
  , ProviderEffect (..)
  , OperatorMaterialEffect (..)
  , CustodyEffect (..)
  , AdminTeardownEffect (..)
  , SesWorkflowRefusal (..)
  , SesWorkflowDecision (..)
  , initialSesWorkflow
  , decideSesWorkflow
  , evolveSesWorkflow
  , activeSesWriters
  )
where

import Codec.Serialise (Serialise)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)

data SesContract = SesContract
  { sesContractDigest :: !Text
  , sesProviderRevision :: !Word
  , sesTargets :: !(Set Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyEvidence = LegacyEvidence
  { legacyCheckpointDigest :: !Text
  , legacyPrincipalArn :: !Text
  , legacyPolicyArn :: !Text
  , legacyAccessKeyIds :: !(Set Text)
  , legacySecretVersions :: !(Set Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CustodyReceipt = CustodyReceipt
  { custodyGeneration :: !Word
  , custodyOpaqueReceipt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetReceipt = TargetReceipt
  { targetGeneration :: !Word
  , targetOpaqueReceipt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Exactly one constructor owns IAM mutation. The frozen constructor owns no
-- writer and carries all evidence required to activate the successor.
data CredentialOwnership
  = LegacyPulumiWriter !Word
  | CredentialMigrationFrozen !Word !LegacyEvidence
  | ProvisionerWriter !Word !Text !LegacyEvidence
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SesWorkflowState = SesWorkflowState
  { workflowContract :: !SesContract
  , workflowOwnership :: !CredentialOwnership
  , workflowProviderCommitted :: !(Maybe Word)
  , workflowSemanticReady :: !(Maybe Word)
  , workflowSmtpGeneration :: !(Maybe Word)
  , workflowCustodyReceipt :: !(Maybe CustodyReceipt)
  , workflowTargetReceipts :: !(Map Text TargetReceipt)
  , workflowLegacyCheckpointReleased :: !Bool
  , workflowLegacyGcReceipt :: !(Maybe (Set Text))
  , workflowCompleted :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SesWorkflowCommand
  = ObserveProvider
  | CommitProviderRevision !Word
  | CommitSemanticReady !Word
  | BeginCredentialMigration !Word !LegacyEvidence
  | CommitLegacyCheckpointReleased
  | CommitMigrationCustodyPrepared !Word !CustodyReceipt
  | ActivateProvisioner !Word !Text
  | CommitSmtpGeneration !Word !CustodyReceipt
  | CommitTargetDelivery !Text !TargetReceipt
  | CommitLegacySecretGc !(Set Text)
  | CompleteSesWorkflow
  | RequestDestroyAwsSes
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderEffect
  = ObserveNonCredentialSesInventory !SesContract
  | ReconcileNonCredentialSesInventory !SesContract
  | AwaitSesSemanticRevision !SesContract
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data OperatorMaterialEffect
  = FreezeLegacySesWriter !Word !LegacyEvidence
  | ReleaseLegacyCredentialCheckpoint !LegacyEvidence
  | AdoptSesCredentialIdentity !Word !Text !LegacyEvidence
  | ReconcileSesSmtpGeneration !Word !Text !Word
  | GarbageCollectLegacySecretVersions !(Set Text)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CustodyEffect
  = IngestSesSmtpSource !Word
  | DeliverSesSmtpGeneration !Text !Word !CustodyReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminTeardownEffect = RunDestroyAwsSesDag
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SesWorkflowEffect
  = ProviderWork !ProviderEffect
  | OperatorMaterialWork !OperatorMaterialEffect
  | CustodyWork !CustodyEffect
  | AdminTeardownWork !AdminTeardownEffect
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SesWorkflowEvent
  = ProviderRevisionCommitted !Word
  | SemanticRevisionCommitted !Word
  | CredentialMigrationStarted !Word !LegacyEvidence
  | LegacyCredentialCheckpointReleased
  | ProvisionerActivated !Word !Text
  | SmtpGenerationCommitted !Word !CustodyReceipt
  | TargetDeliveryCommitted !Text !TargetReceipt
  | LegacySecretGcCommitted !(Set Text)
  | SesWorkflowCompleted
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SesWorkflowRefusal
  = RevisionMismatch !Word !Word
  | MigrationEpochMustAdvance
  | MigrationEvidenceConflict
  | LegacyWriterNotFrozen
  | LegacyCheckpointNotReleased
  | MigrationCustodyNotPrepared
  | MigrationTargetsNotConverged !(Set Text)
  | ProvisionerNotActive
  | SmtpGenerationMustAdvance
  | UnresolvedTargetDeliveries !(Set Text)
  | CustodyGenerationMismatch
  | UnknownSesTarget !Text
  | TargetGenerationMismatch
  | LegacySecretGcBeforeCutover
  | LegacySecretGcBeforeTargetConvergence !(Set Text)
  | LegacySecretGcIncomplete !(Set Text)
  | WorkflowNotConverged
  | WorkflowAlreadyComplete
  deriving stock (Eq, Show)

data SesWorkflowDecision
  = EmitSesEffect !SesWorkflowEffect
  | RecordSesEvent !SesWorkflowEvent
  | SesAlreadyApplied
  | RefuseSesWorkflow !SesWorkflowRefusal
  deriving stock (Eq, Show)

initialSesWorkflow :: SesContract -> Word -> SesWorkflowState
initialSesWorkflow contract legacyEpoch =
  SesWorkflowState
    contract
    (LegacyPulumiWriter legacyEpoch)
    Nothing
    Nothing
    Nothing
    Nothing
    Map.empty
    False
    Nothing
    False

activeSesWriters :: SesWorkflowState -> Set Text
activeSesWriters state = case workflowOwnership state of
  LegacyPulumiWriter _ -> Set.singleton "pulumi"
  CredentialMigrationFrozen _ _ -> Set.empty
  ProvisionerWriter {} -> Set.singleton "credential-provisioner"

decideSesWorkflow :: SesWorkflowState -> SesWorkflowCommand -> SesWorkflowDecision
decideSesWorkflow state command
  | workflowCompleted state = case command of
      RequestDestroyAwsSes -> EmitSesEffect (AdminTeardownWork RunDestroyAwsSesDag)
      CompleteSesWorkflow -> SesAlreadyApplied
      _ -> RefuseSesWorkflow WorkflowAlreadyComplete
  | otherwise = decideOpen state command

decideOpen :: SesWorkflowState -> SesWorkflowCommand -> SesWorkflowDecision
decideOpen state command = case command of
  ObserveProvider -> case workflowProviderCommitted state of
    Nothing -> EmitSesEffect (ProviderWork (ReconcileNonCredentialSesInventory contract))
    Just revision
      | revision == wanted -> EmitSesEffect (ProviderWork (AwaitSesSemanticRevision contract))
      | otherwise -> EmitSesEffect (ProviderWork (ObserveNonCredentialSesInventory contract))
  CommitProviderRevision revision -> exactRevision revision (ProviderRevisionCommitted revision)
  CommitSemanticReady revision
    | workflowProviderCommitted state /= Just revision ->
        RefuseSesWorkflow (RevisionMismatch wanted revision)
    | otherwise -> exactRevision revision (SemanticRevisionCommitted revision)
  BeginCredentialMigration epoch evidence -> case workflowOwnership state of
    LegacyPulumiWriter current
      | epoch > current -> EmitSesEffect (OperatorMaterialWork (FreezeLegacySesWriter epoch evidence))
      | otherwise -> RefuseSesWorkflow MigrationEpochMustAdvance
    CredentialMigrationFrozen current recorded
      | current == epoch && recorded == evidence -> SesAlreadyApplied
      | otherwise -> RefuseSesWorkflow MigrationEvidenceConflict
    ProvisionerWriter {} -> RefuseSesWorkflow MigrationEvidenceConflict
  CommitLegacyCheckpointReleased -> case workflowOwnership state of
    CredentialMigrationFrozen _ evidence
      | workflowLegacyCheckpointReleased state -> SesAlreadyApplied
      | otherwise -> EmitSesEffect (OperatorMaterialWork (ReleaseLegacyCredentialCheckpoint evidence))
    _ -> RefuseSesWorkflow LegacyWriterNotFrozen
  CommitMigrationCustodyPrepared generation receipt -> case workflowOwnership state of
    CredentialMigrationFrozen _ _
      | custodyGeneration receipt /= generation -> RefuseSesWorkflow CustodyGenerationMismatch
      | workflowCustodyReceipt state == Just receipt -> SesAlreadyApplied
      | otherwise -> RecordSesEvent (SmtpGenerationCommitted generation receipt)
    _ -> RefuseSesWorkflow LegacyWriterNotFrozen
  ActivateProvisioner epoch identity -> case workflowOwnership state of
    CredentialMigrationFrozen frozenEpoch evidence
      | not (workflowLegacyCheckpointReleased state) -> RefuseSesWorkflow LegacyCheckpointNotReleased
      | workflowCustodyReceipt state == Nothing -> RefuseSesWorkflow MigrationCustodyNotPrepared
      | not (Set.null missingTargets) -> RefuseSesWorkflow (MigrationTargetsNotConverged missingTargets)
      | epoch /= frozenEpoch -> RefuseSesWorkflow MigrationEvidenceConflict
      | otherwise ->
          EmitSesEffect (OperatorMaterialWork (AdoptSesCredentialIdentity epoch identity evidence))
    ProvisionerWriter activeEpoch activeIdentity _
      | activeEpoch == epoch && activeIdentity == identity -> SesAlreadyApplied
      | otherwise -> RefuseSesWorkflow MigrationEvidenceConflict
    _ -> RefuseSesWorkflow LegacyWriterNotFrozen
  CommitSmtpGeneration generation receipt -> case workflowOwnership state of
    ProvisionerWriter _ identity _
      | custodyGeneration receipt /= generation -> RefuseSesWorkflow CustodyGenerationMismatch
      | maybe False (>= generation) (workflowSmtpGeneration state) -> SesAlreadyApplied
      | not (Set.null unresolvedTargets) ->
          RefuseSesWorkflow (UnresolvedTargetDeliveries unresolvedTargets)
      | maybe False (\previous -> previous + 1 /= generation) (workflowSmtpGeneration state) ->
          RefuseSesWorkflow SmtpGenerationMustAdvance
      | otherwise ->
          EmitSesEffect (OperatorMaterialWork (ReconcileSesSmtpGeneration wanted identity generation))
    _ -> RefuseSesWorkflow ProvisionerNotActive
  CommitTargetDelivery target receipt
    | target `Set.notMember` sesTargets contract -> RefuseSesWorkflow (UnknownSesTarget target)
    | Just (targetGeneration receipt) /= workflowSmtpGeneration state ->
        RefuseSesWorkflow TargetGenerationMismatch
    | Map.lookup target (workflowTargetReceipts state) == Just receipt -> SesAlreadyApplied
    | otherwise -> case workflowCustodyReceipt state of
        Nothing -> RefuseSesWorkflow TargetGenerationMismatch
        Just custody -> EmitSesEffect (CustodyWork (DeliverSesSmtpGeneration target (targetGeneration receipt) custody))
  CommitLegacySecretGc versions -> case workflowOwnership state of
    ProvisionerWriter {}
      | not (workflowLegacyCheckpointReleased state) || workflowCustodyReceipt state == Nothing ->
          RefuseSesWorkflow LegacySecretGcBeforeCutover
      | not (Set.null unresolvedTargets) ->
          RefuseSesWorkflow (LegacySecretGcBeforeTargetConvergence unresolvedTargets)
      | versions /= legacyVersions state ->
          RefuseSesWorkflow (LegacySecretGcIncomplete (legacyVersions state `Set.difference` versions))
      | workflowLegacyGcReceipt state == Just versions -> SesAlreadyApplied
      | otherwise -> EmitSesEffect (OperatorMaterialWork (GarbageCollectLegacySecretVersions versions))
    _ -> RefuseSesWorkflow LegacySecretGcBeforeCutover
  CompleteSesWorkflow
    | converged state -> RecordSesEvent SesWorkflowCompleted
    | otherwise -> RefuseSesWorkflow WorkflowNotConverged
  RequestDestroyAwsSes -> EmitSesEffect (AdminTeardownWork RunDestroyAwsSesDag)
 where
  contract = workflowContract state
  wanted = sesProviderRevision contract
  missingTargets = sesTargets contract `Set.difference` Map.keysSet (workflowTargetReceipts state)
  unresolvedTargets = unresolvedTargetSet state
  exactRevision actual event
    | actual == wanted = RecordSesEvent event
    | otherwise = RefuseSesWorkflow (RevisionMismatch wanted actual)

legacyVersions :: SesWorkflowState -> Set Text
legacyVersions state = case workflowOwnership state of
  CredentialMigrationFrozen _ evidence -> legacySecretVersions evidence
  ProvisionerWriter _ _ evidence -> legacySecretVersions evidence
  _ -> Set.empty

converged :: SesWorkflowState -> Bool
converged state =
  workflowProviderCommitted state == Just wanted
    && workflowSemanticReady state == Just wanted
    && workflowSmtpGeneration state /= Nothing
    && Map.keysSet (workflowTargetReceipts state) == sesTargets contract
    && workflowLegacyGcReceipt state /= Nothing
 where
  contract = workflowContract state
  wanted = sesProviderRevision contract

unresolvedTargetSet :: SesWorkflowState -> Set Text
unresolvedTargetSet state = case workflowSmtpGeneration state of
  Nothing -> Set.empty
  Just generation ->
    Set.filter
      (\target -> maybe True ((/= generation) . targetGeneration) (Map.lookup target receipts))
      (sesTargets (workflowContract state))
 where
  receipts = workflowTargetReceipts state

evolveSesWorkflow :: SesWorkflowState -> SesWorkflowEvent -> SesWorkflowState
evolveSesWorkflow state event = case event of
  ProviderRevisionCommitted revision -> state {workflowProviderCommitted = Just revision}
  SemanticRevisionCommitted revision -> state {workflowSemanticReady = Just revision}
  CredentialMigrationStarted epoch evidence -> state {workflowOwnership = CredentialMigrationFrozen epoch evidence}
  LegacyCredentialCheckpointReleased -> state {workflowLegacyCheckpointReleased = True}
  ProvisionerActivated epoch identity -> case workflowOwnership state of
    CredentialMigrationFrozen _ evidence ->
      state {workflowOwnership = ProvisionerWriter epoch identity evidence}
    _ -> state
  SmtpGenerationCommitted generation receipt ->
    state
      { workflowSmtpGeneration = Just generation
      , workflowCustodyReceipt = Just receipt
      }
  TargetDeliveryCommitted target receipt ->
    state {workflowTargetReceipts = Map.insert target receipt (workflowTargetReceipts state)}
  LegacySecretGcCommitted versions -> state {workflowLegacyGcReceipt = Just versions}
  SesWorkflowCompleted -> state {workflowCompleted = True}
