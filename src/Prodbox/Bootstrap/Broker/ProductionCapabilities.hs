{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

-- | Structural completeness proof for the production Bootstrap Broker.
-- Readiness is derived from the exact registered boundary inventory plus live
-- dependency observations; it is never opened by a manual Boolean sentinel.
module Prodbox.Bootstrap.Broker.ProductionCapabilities
  ( ProductionCapabilityBinding (..)
  , ProductionCapabilityRegistry
  , ProductionDependencyReadiness (..)
  , mkProductionCapabilityRegistry
  , productionCapabilityRegistryBindings
  , productionCapabilityRegistryComplete
  , productionCapabilityInventoryComplete
  , productionCapabilityRegistrationInventory
  , productionCapabilityUniverse
  , productionReadinessDecision
  , physicalCapabilityBinding
  , localCapabilityBinding
  )
where

import Data.List (sort)
import Prodbox.Bootstrap.Broker.Engine
  ( BrokerLocalCall (..)
  , BrokerPhysicalCall (..)
  , BrokerProgramEvidenceBoundary (..)
  , BrokerSecretWorkerBoundary (..)
  )
import Prodbox.Bootstrap.Broker.EngineSecretWorker
  ( EngineSecretWorkerBoundary (..)
  )
import Prodbox.Bootstrap.Broker.EngineSecretWorker qualified as EngineSecretWorker
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( GeneratedChildRecoveryActionKind (..)
  , GeneratedRootActionKind (..)
  , PgpBoundary
  , allGeneratedChildRecoveryActionKinds
  , allGeneratedRootActionKinds
  , decryptRecoveryShares
  , prepareRecoveryRecipient
  , resumePreparedInitRecipients
  , sealFinalUnlockPayload
  , verifyCompiledBurnRecipient
  )
import Prodbox.Bootstrap.Broker.ProductionStore
  ( ProductionTransitRotationBoundary (..)
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  )
import Prodbox.Bootstrap.Broker.StoreBoundary qualified as StoreBoundary

-- | Every independently replaceable arm in the production Broker boundary.
-- Deriving 'Bounded' makes a new constructor enter the required universe even
-- before it is added to the explicit registration inventory.
data ProductionCapabilityBinding
  = ProductionEvidencePristineStorage
  | ProductionEvidenceUnsealRecoveryCustody
  | ProductionEvidenceUnlockRotationCustody
  | ProductionEvidenceBaselineCustodyAndSession
  | ProductionEvidenceAmbiguousReset
  | ProductionEvidenceChildCustody
  | ProductionEvidenceChildRecoveryDelivery
  | ProductionEvidenceChildRecoveryObservation
  | ProductionStoreObserveFence
  | ProductionStoreCasFence
  | ProductionStoreCasRetireFence
  | ProductionStoreReleaseFence
  | ProductionStoreObserveStorageGeneration
  | ProductionStoreAdvanceStorageGeneration
  | ProductionStoreReadRootInitJournal
  | ProductionStoreReadRootInitJournalForReset
  | ProductionStoreCreateRootInitJournal
  | ProductionStoreCasRootInitJournal
  | ProductionStoreReadPreparedInitEnvelope
  | ProductionStoreCreatePreparedInitEnvelope
  | ProductionStoreDeletePreparedInitEnvelope
  | ProductionStoreReadEncryptedInitResponse
  | ProductionStoreCreateEncryptedInitResponse
  | ProductionStoreReadFinalUnlockBundle
  | ProductionStorePromoteFinalUnlockBundle
  | ProductionStoreCasFinalUnlockBundle
  | ProductionStoreReadRootSessionJournal
  | ProductionStoreCreateRootSessionJournal
  | ProductionStoreCasRootSessionJournal
  | ProductionStoreReadChildEncryptedReceipt
  | ProductionStoreCreateChildEncryptedReceipt
  | ProductionStoreDeleteChildEncryptedReceipt
  | ProductionStoreReadChildCustodyJournal
  | ProductionStoreCreateChildCustodyJournal
  | ProductionStoreCasChildCustodyJournal
  | ProductionStoreReadChildRecoveryDelivery
  | ProductionStoreCreateChildRecoveryDelivery
  | ProductionStoreDeleteChildRecoveryDelivery
  | ProductionStoreReadChildRecoveryJournal
  | ProductionStoreCreateChildRecoveryJournal
  | ProductionStoreCasChildRecoveryJournal
  | ProductionStoreReadPostUnsealHandoff
  | ProductionStoreCreatePostUnsealHandoff
  | ProductionStoreCasPostUnsealHandoff
  | ProductionStoreReadSecretWorkerCheckpoint
  | ProductionStoreCreateSecretWorkerCheckpoint
  | ProductionStoreCasSecretWorkerCheckpoint
  | ProductionStorePlanTransitRotation
  | ProductionStoreCompleteTransitRotation
  | ProductionPgpVerifyCompiledBurnRecipient
  | ProductionPgpPrepareRecoveryRecipient
  | ProductionPgpResumePreparedRecipients
  | ProductionPgpDecryptRecoveryShares
  | ProductionPgpSealFinalUnlockPayload
  | ProductionPgpGeneratedRootRecipient
  | ProductionPgpGeneratedChildRecoveryRecipient
  | ProductionPgpGeneratedRootObserveAccessor
  | ProductionPgpGeneratedRootApplyBaseline
  | ProductionPgpGeneratedRootReadBackBaseline
  | ProductionPgpGeneratedRootRevokeAccessor
  | ProductionPgpGeneratedChildObserveAccessor
  | ProductionPgpGeneratedChildApplyRepair
  | ProductionPgpGeneratedChildReadBackRepair
  | ProductionPgpGeneratedChildRevokeAccessor
  | ProductionWorkerObserveMonotonicNow
  | ProductionWorkerAllocateIntent
  | ProductionWorkerCreateWorkload
  | ProductionWorkerObserveAttestation
  | ProductionWorkerDiscardUnreceipted
  | ProductionWorkerCheckpointPermit
  | ProductionWorkerReadCheckpoint
  | ProductionWorkerCreateCheckpoint
  | ProductionWorkerCasCheckpoint
  | ProductionWorkerRevokeSession
  | ProductionWorkerObserveExit
  | ProductionWorkerDeletePod
  | ProductionWorkerObserveAbsence
  | ProductionWorkerExecutePhysicalCall
  | ProductionPhysicalHealth
  | ProductionPhysicalReadiness
  | ProductionPhysicalObserveVaultStatus
  | ProductionPhysicalPrepareRootInitRecipients
  | ProductionPhysicalResumeRootInitRecipients
  | ProductionPhysicalInitializeVault
  | ProductionPhysicalSealFinalUnlockBundle
  | ProductionPhysicalUnsealVault
  | ProductionPhysicalSealVault
  | ProductionPhysicalRotateUnlockBundle
  | ProductionPhysicalRotateTransitKey
  | ProductionPhysicalResetAmbiguousInitialization
  | ProductionPhysicalCancelIncompleteGenerateRoot
  | ProductionPhysicalInventoryRootAccessors
  | ProductionPhysicalRevokeRootAccessor
  | ProductionPhysicalProveRootAccessorsAbsent
  | ProductionPhysicalStartGenerateRoot
  | ProductionPhysicalAwaitGeneratedRootCiphertext
  | ProductionPhysicalCleanupProvisionerSessions
  | ProductionPhysicalLoginProvisioner
  | ProductionPhysicalApplyProvisionerBaseline
  | ProductionPhysicalReadBackProvisionerBaseline
  | ProductionPhysicalRevokeProvisionerSession
  | ProductionPhysicalProveProvisionerSessionAbsent
  | ProductionPhysicalObservePostUnsealConsumer
  | ProductionPhysicalObserveVaultPkiStatus
  | ProductionPhysicalIssueVaultPkiTestCertificate
  | ProductionPhysicalObserveChildRecoveryConsumption
  | ProductionPhysicalConsumeChildRecovery
  | ProductionPhysicalCancelChildIncompleteGenerateRoot
  | ProductionPhysicalInventoryChildRootAccessors
  | ProductionPhysicalRevokeChildRootAccessor
  | ProductionPhysicalProveChildRootAccessorsAbsent
  | ProductionPhysicalStartChildGenerateRoot
  | ProductionPhysicalAwaitChildGeneratedRootCiphertext
  | ProductionLocalRecoverRootInit
  | ProductionLocalAcknowledgeRecoveryCustody
  | ProductionLocalCaptureChildEncryptedReceipt
  | ProductionLocalPrepareChildRecoveryDelivery
  deriving (Eq, Ord, Show, Enum, Bounded)

newtype ProductionCapabilityRegistry = ProductionCapabilityRegistry
  { productionCapabilityRegistryBindings :: [ProductionCapabilityBinding]
  }

data ProductionDependencyReadiness = ProductionDependencyReadiness
  { productionStoreDependencyReady :: !Bool
  , productionVaultDependencyReady :: !Bool
  , productionPgpDependencyReady :: !Bool
  , productionLeaseDependencyReady :: !Bool
  , productionControllerImageDependencyReady :: !Bool
  }
  deriving (Eq, Show)

-- | Register the actual production records and the two total GADT
-- interpreters. 'seq' is intentional: the registry is constructed from the
-- installed boundaries/functions, rather than from an unrelated constant.
-- Rank-n workflow fields are represented by their closed action-kind
-- inventories because those selectors cannot be reified as first-class
-- monotypes.
mkProductionCapabilityRegistry
  :: BrokerProgramEvidenceBoundary m
  -> BootstrapStoreBoundary m
  -> ProductionTransitRotationBoundary m
  -> PgpBoundary m
  -> BrokerSecretWorkerBoundary m
  -> ( forall operation result
        . BrokerPhysicalCall operation result
       -> m (Either boundaryError result)
     )
  -> (forall result. BrokerLocalCall result -> m (Either boundaryError result))
  -> ProductionCapabilityRegistry
mkProductionCapabilityRegistry evidence store transitRotation pgp worker physical local =
  ProductionCapabilityRegistry
    ( registerEvidenceBoundary evidence
        <> registerStoreBoundary store
        <> registerTransitRotationBoundary transitRotation
        <> registerPgpBoundary pgp
        <> registerSecretWorkerBoundary worker
        <> registerPhysicalBoundary physical
        <> registerLocalBoundary local
    )

productionCapabilityUniverse :: [ProductionCapabilityBinding]
productionCapabilityUniverse = [minBound .. maxBound]

-- | Explicit expected production registration. This deliberately does not use
-- @[minBound .. maxBound]@: adding a required constructor without installing
-- it makes the completeness comparison fail closed.
productionCapabilityRegistrationInventory :: [ProductionCapabilityBinding]
productionCapabilityRegistrationInventory =
  evidenceBindings
    <> storeBindings
    <> transitRotationBindings
    <> pgpBindings
    <> workerBindings
    <> physicalBindings
    <> localBindings

productionCapabilityInventoryComplete
  :: [ProductionCapabilityBinding] -> Bool
productionCapabilityInventoryComplete bindings =
  sort bindings == productionCapabilityUniverse

productionCapabilityRegistryComplete :: ProductionCapabilityRegistry -> Bool
productionCapabilityRegistryComplete =
  productionCapabilityInventoryComplete . productionCapabilityRegistryBindings

productionReadinessDecision
  :: [ProductionCapabilityBinding]
  -> ProductionDependencyReadiness
  -> Bool
productionReadinessDecision bindings dependencies =
  productionCapabilityInventoryComplete bindings
    && productionStoreDependencyReady dependencies
    && productionVaultDependencyReady dependencies
    && productionPgpDependencyReady dependencies
    && productionLeaseDependencyReady dependencies
    && productionControllerImageDependencyReady dependencies

physicalCapabilityBinding
  :: BrokerPhysicalCall operation result -> ProductionCapabilityBinding
physicalCapabilityBinding call = case call of
  PhysicalHealth {} -> ProductionPhysicalHealth
  PhysicalReadiness {} -> ProductionPhysicalReadiness
  PhysicalObserveVaultStatus {} -> ProductionPhysicalObserveVaultStatus
  PhysicalPrepareRootInitRecipients {} -> ProductionPhysicalPrepareRootInitRecipients
  PhysicalResumeRootInitRecipients {} -> ProductionPhysicalResumeRootInitRecipients
  PhysicalInitializeVault {} -> ProductionPhysicalInitializeVault
  PhysicalSealFinalUnlockBundle {} -> ProductionPhysicalSealFinalUnlockBundle
  PhysicalUnsealVault {} -> ProductionPhysicalUnsealVault
  PhysicalSealVault {} -> ProductionPhysicalSealVault
  PhysicalRotateUnlockBundle {} -> ProductionPhysicalRotateUnlockBundle
  PhysicalRotateTransitKey {} -> ProductionPhysicalRotateTransitKey
  PhysicalResetAmbiguousInitialization {} -> ProductionPhysicalResetAmbiguousInitialization
  PhysicalCancelIncompleteGenerateRoot {} -> ProductionPhysicalCancelIncompleteGenerateRoot
  PhysicalInventoryRootAccessors {} -> ProductionPhysicalInventoryRootAccessors
  PhysicalRevokeRootAccessor {} -> ProductionPhysicalRevokeRootAccessor
  PhysicalProveRootAccessorsAbsent {} -> ProductionPhysicalProveRootAccessorsAbsent
  PhysicalStartGenerateRoot {} -> ProductionPhysicalStartGenerateRoot
  PhysicalAwaitGeneratedRootCiphertext {} -> ProductionPhysicalAwaitGeneratedRootCiphertext
  PhysicalCleanupProvisionerSessions {} -> ProductionPhysicalCleanupProvisionerSessions
  PhysicalLoginProvisioner {} -> ProductionPhysicalLoginProvisioner
  PhysicalApplyProvisionerBaseline {} -> ProductionPhysicalApplyProvisionerBaseline
  PhysicalReadBackProvisionerBaseline {} -> ProductionPhysicalReadBackProvisionerBaseline
  PhysicalRevokeProvisionerSession {} -> ProductionPhysicalRevokeProvisionerSession
  PhysicalProveProvisionerSessionAbsent {} -> ProductionPhysicalProveProvisionerSessionAbsent
  PhysicalObservePostUnsealConsumer {} -> ProductionPhysicalObservePostUnsealConsumer
  PhysicalObserveVaultPkiStatus {} -> ProductionPhysicalObserveVaultPkiStatus
  PhysicalIssueVaultPkiTestCertificate {} -> ProductionPhysicalIssueVaultPkiTestCertificate
  PhysicalObserveChildRecoveryConsumption {} -> ProductionPhysicalObserveChildRecoveryConsumption
  PhysicalConsumeChildRecovery {} -> ProductionPhysicalConsumeChildRecovery
  PhysicalCancelChildIncompleteGenerateRoot {} -> ProductionPhysicalCancelChildIncompleteGenerateRoot
  PhysicalInventoryChildRootAccessors {} -> ProductionPhysicalInventoryChildRootAccessors
  PhysicalRevokeChildRootAccessor {} -> ProductionPhysicalRevokeChildRootAccessor
  PhysicalProveChildRootAccessorsAbsent {} -> ProductionPhysicalProveChildRootAccessorsAbsent
  PhysicalStartChildGenerateRoot {} -> ProductionPhysicalStartChildGenerateRoot
  PhysicalAwaitChildGeneratedRootCiphertext {} ->
    ProductionPhysicalAwaitChildGeneratedRootCiphertext

localCapabilityBinding :: BrokerLocalCall result -> ProductionCapabilityBinding
localCapabilityBinding call = case call of
  LocalRecoverRootInitCall {} -> ProductionLocalRecoverRootInit
  LocalAcknowledgeRecoveryCustody {} -> ProductionLocalAcknowledgeRecoveryCustody
  LocalCaptureChildEncryptedReceipt {} -> ProductionLocalCaptureChildEncryptedReceipt
  LocalPrepareChildRecoveryDelivery {} -> ProductionLocalPrepareChildRecoveryDelivery

registerEvidenceBoundary
  :: BrokerProgramEvidenceBoundary m -> [ProductionCapabilityBinding]
registerEvidenceBoundary boundary =
  resolvePristineStorageProof boundary `seq`
    resolveUnsealRecoveryCustody boundary `seq`
      resolveUnlockRotationCustody boundary `seq`
        resolveBaselineCustodyAndSession boundary `seq`
          resolveAmbiguousResetEvidence boundary `seq`
            resolveChildCustodyBinding boundary `seq`
              resolveChildRecoveryDeliveryEvidence boundary `seq`
                resolveChildRecoveryObservation boundary `seq`
                  evidenceBindings

registerStoreBoundary
  :: BootstrapStoreBoundary m -> [ProductionCapabilityBinding]
registerStoreBoundary boundary =
  observeBootstrapSessionFence boundary `seq`
    casBootstrapSessionFence boundary `seq`
      casRetireBootstrapSessionFence boundary `seq`
        releaseBootstrapSessionFence boundary `seq`
          observeVaultStorageGeneration boundary `seq`
            advanceVaultStorageGeneration boundary `seq`
              readRootInitJournal boundary `seq`
                readRootInitJournalForReset boundary `seq`
                  createRootInitJournal boundary `seq`
                    casRootInitJournal boundary `seq`
                      readPreparedInitEnvelope boundary `seq`
                        createPreparedInitEnvelope boundary `seq`
                          deletePreparedInitEnvelope boundary `seq`
                            readEncryptedInitResponse boundary `seq`
                              createEncryptedInitResponse boundary `seq`
                                readFinalUnlockBundle boundary `seq`
                                  promoteFinalUnlockBundle boundary `seq`
                                    casFinalUnlockBundle boundary `seq`
                                      readRootSessionJournal boundary `seq`
                                        createRootSessionJournal boundary `seq`
                                          casRootSessionJournal boundary `seq`
                                            readChildEncryptedReceipt boundary `seq`
                                              createChildEncryptedReceipt boundary `seq`
                                                deleteChildEncryptedReceipt boundary `seq`
                                                  readChildCustodyJournal boundary `seq`
                                                    createChildCustodyJournal boundary `seq`
                                                      casChildCustodyJournal boundary `seq`
                                                        readChildRecoveryDelivery boundary `seq`
                                                          createChildRecoveryDelivery boundary `seq`
                                                            deleteChildRecoveryDelivery boundary `seq`
                                                              readChildRecoveryJournal boundary `seq`
                                                                createChildRecoveryJournal boundary `seq`
                                                                  casChildRecoveryJournal boundary `seq`
                                                                    readPostUnsealHandoff boundary `seq`
                                                                      createPostUnsealHandoff boundary `seq`
                                                                        casPostUnsealHandoff boundary `seq`
                                                                          StoreBoundary.readSecretWorkerCheckpoint boundary `seq`
                                                                            StoreBoundary.createSecretWorkerCheckpoint boundary `seq`
                                                                              StoreBoundary.casSecretWorkerCheckpoint boundary `seq`
                                                                                storeBindings

registerPgpBoundary :: PgpBoundary m -> [ProductionCapabilityBinding]
registerPgpBoundary boundary =
  boundary `seq`
    verifyCompiledBurnRecipient boundary `seq`
      prepareRecoveryRecipient boundary `seq`
        resumePreparedInitRecipients boundary `seq`
          decryptRecoveryShares boundary `seq`
            sealFinalUnlockPayload boundary `seq`
              pgpBindings

registerTransitRotationBoundary
  :: ProductionTransitRotationBoundary m -> [ProductionCapabilityBinding]
registerTransitRotationBoundary boundary =
  planTransitRotation boundary `seq`
    completeTransitRotation boundary `seq`
      transitRotationBindings

registerSecretWorkerBoundary
  :: BrokerSecretWorkerBoundary m -> [ProductionCapabilityBinding]
registerSecretWorkerBoundary boundary =
  let driver = brokerSecretWorkerDriverBoundary boundary
   in boundary `seq`
        driver `seq`
          observeSecretWorkerMonotonicNow driver `seq`
            allocateSecretWorkerIntent driver `seq`
              createSecretWorkerWorkload driver `seq`
                observeSecretWorkerAttestation driver `seq`
                  discardUnreceiptedSecretWorker driver `seq`
                    withSecretWorkerCheckpointPermit driver `seq`
                      EngineSecretWorker.readSecretWorkerCheckpoint driver `seq`
                        EngineSecretWorker.createSecretWorkerCheckpoint driver `seq`
                          EngineSecretWorker.casSecretWorkerCheckpoint driver `seq`
                            revokeSecretWorkerSession driver `seq`
                              observeSecretWorkerExit driver `seq`
                                deleteSecretWorkerPod driver `seq`
                                  observeSecretWorkerAbsence driver `seq`
                                    workerBindings

registerPhysicalBoundary
  :: ( forall operation result
        . BrokerPhysicalCall operation result
       -> m (Either boundaryError result)
     )
  -> [ProductionCapabilityBinding]
registerPhysicalBoundary boundary = boundary `seq` physicalBindings

registerLocalBoundary
  :: (forall result. BrokerLocalCall result -> m (Either boundaryError result))
  -> [ProductionCapabilityBinding]
registerLocalBoundary boundary = boundary `seq` localBindings

evidenceBindings :: [ProductionCapabilityBinding]
evidenceBindings =
  [ ProductionEvidencePristineStorage
  , ProductionEvidenceUnsealRecoveryCustody
  , ProductionEvidenceUnlockRotationCustody
  , ProductionEvidenceBaselineCustodyAndSession
  , ProductionEvidenceAmbiguousReset
  , ProductionEvidenceChildCustody
  , ProductionEvidenceChildRecoveryDelivery
  , ProductionEvidenceChildRecoveryObservation
  ]

storeBindings :: [ProductionCapabilityBinding]
storeBindings =
  [ ProductionStoreObserveFence
  , ProductionStoreCasFence
  , ProductionStoreCasRetireFence
  , ProductionStoreReleaseFence
  , ProductionStoreObserveStorageGeneration
  , ProductionStoreAdvanceStorageGeneration
  , ProductionStoreReadRootInitJournal
  , ProductionStoreReadRootInitJournalForReset
  , ProductionStoreCreateRootInitJournal
  , ProductionStoreCasRootInitJournal
  , ProductionStoreReadPreparedInitEnvelope
  , ProductionStoreCreatePreparedInitEnvelope
  , ProductionStoreDeletePreparedInitEnvelope
  , ProductionStoreReadEncryptedInitResponse
  , ProductionStoreCreateEncryptedInitResponse
  , ProductionStoreReadFinalUnlockBundle
  , ProductionStorePromoteFinalUnlockBundle
  , ProductionStoreCasFinalUnlockBundle
  , ProductionStoreReadRootSessionJournal
  , ProductionStoreCreateRootSessionJournal
  , ProductionStoreCasRootSessionJournal
  , ProductionStoreReadChildEncryptedReceipt
  , ProductionStoreCreateChildEncryptedReceipt
  , ProductionStoreDeleteChildEncryptedReceipt
  , ProductionStoreReadChildCustodyJournal
  , ProductionStoreCreateChildCustodyJournal
  , ProductionStoreCasChildCustodyJournal
  , ProductionStoreReadChildRecoveryDelivery
  , ProductionStoreCreateChildRecoveryDelivery
  , ProductionStoreDeleteChildRecoveryDelivery
  , ProductionStoreReadChildRecoveryJournal
  , ProductionStoreCreateChildRecoveryJournal
  , ProductionStoreCasChildRecoveryJournal
  , ProductionStoreReadPostUnsealHandoff
  , ProductionStoreCreatePostUnsealHandoff
  , ProductionStoreCasPostUnsealHandoff
  , ProductionStoreReadSecretWorkerCheckpoint
  , ProductionStoreCreateSecretWorkerCheckpoint
  , ProductionStoreCasSecretWorkerCheckpoint
  ]

transitRotationBindings :: [ProductionCapabilityBinding]
transitRotationBindings =
  [ ProductionStorePlanTransitRotation
  , ProductionStoreCompleteTransitRotation
  ]

pgpBindings :: [ProductionCapabilityBinding]
pgpBindings =
  [ ProductionPgpVerifyCompiledBurnRecipient
  , ProductionPgpPrepareRecoveryRecipient
  , ProductionPgpResumePreparedRecipients
  , ProductionPgpDecryptRecoveryShares
  , ProductionPgpSealFinalUnlockPayload
  , ProductionPgpGeneratedRootRecipient
  , ProductionPgpGeneratedChildRecoveryRecipient
  ]
    <> fmap generatedRootActionBinding allGeneratedRootActionKinds
    <> fmap generatedChildActionBinding allGeneratedChildRecoveryActionKinds

generatedRootActionBinding
  :: GeneratedRootActionKind -> ProductionCapabilityBinding
generatedRootActionBinding kind = case kind of
  GeneratedRootObserveSelfAction -> ProductionPgpGeneratedRootObserveAccessor
  GeneratedRootApplyBaselineAction -> ProductionPgpGeneratedRootApplyBaseline
  GeneratedRootReadBackBaselineAction -> ProductionPgpGeneratedRootReadBackBaseline
  GeneratedRootRevokeSelfAction -> ProductionPgpGeneratedRootRevokeAccessor

generatedChildActionBinding
  :: GeneratedChildRecoveryActionKind -> ProductionCapabilityBinding
generatedChildActionBinding kind = case kind of
  GeneratedChildRecoveryObserveSelfAction -> ProductionPgpGeneratedChildObserveAccessor
  GeneratedChildRecoveryApplyRepairAction -> ProductionPgpGeneratedChildApplyRepair
  GeneratedChildRecoveryReadBackRepairAction -> ProductionPgpGeneratedChildReadBackRepair
  GeneratedChildRecoveryRevokeSelfAction -> ProductionPgpGeneratedChildRevokeAccessor

workerBindings :: [ProductionCapabilityBinding]
workerBindings =
  [ ProductionWorkerObserveMonotonicNow
  , ProductionWorkerAllocateIntent
  , ProductionWorkerCreateWorkload
  , ProductionWorkerObserveAttestation
  , ProductionWorkerDiscardUnreceipted
  , ProductionWorkerCheckpointPermit
  , ProductionWorkerReadCheckpoint
  , ProductionWorkerCreateCheckpoint
  , ProductionWorkerCasCheckpoint
  , ProductionWorkerRevokeSession
  , ProductionWorkerObserveExit
  , ProductionWorkerDeletePod
  , ProductionWorkerObserveAbsence
  , ProductionWorkerExecutePhysicalCall
  ]

physicalBindings :: [ProductionCapabilityBinding]
physicalBindings =
  [ ProductionPhysicalHealth
  , ProductionPhysicalReadiness
  , ProductionPhysicalObserveVaultStatus
  , ProductionPhysicalPrepareRootInitRecipients
  , ProductionPhysicalResumeRootInitRecipients
  , ProductionPhysicalInitializeVault
  , ProductionPhysicalSealFinalUnlockBundle
  , ProductionPhysicalUnsealVault
  , ProductionPhysicalSealVault
  , ProductionPhysicalRotateUnlockBundle
  , ProductionPhysicalRotateTransitKey
  , ProductionPhysicalResetAmbiguousInitialization
  , ProductionPhysicalCancelIncompleteGenerateRoot
  , ProductionPhysicalInventoryRootAccessors
  , ProductionPhysicalRevokeRootAccessor
  , ProductionPhysicalProveRootAccessorsAbsent
  , ProductionPhysicalStartGenerateRoot
  , ProductionPhysicalAwaitGeneratedRootCiphertext
  , ProductionPhysicalCleanupProvisionerSessions
  , ProductionPhysicalLoginProvisioner
  , ProductionPhysicalApplyProvisionerBaseline
  , ProductionPhysicalReadBackProvisionerBaseline
  , ProductionPhysicalRevokeProvisionerSession
  , ProductionPhysicalProveProvisionerSessionAbsent
  , ProductionPhysicalObservePostUnsealConsumer
  , ProductionPhysicalObserveVaultPkiStatus
  , ProductionPhysicalIssueVaultPkiTestCertificate
  , ProductionPhysicalObserveChildRecoveryConsumption
  , ProductionPhysicalConsumeChildRecovery
  , ProductionPhysicalCancelChildIncompleteGenerateRoot
  , ProductionPhysicalInventoryChildRootAccessors
  , ProductionPhysicalRevokeChildRootAccessor
  , ProductionPhysicalProveChildRootAccessorsAbsent
  , ProductionPhysicalStartChildGenerateRoot
  , ProductionPhysicalAwaitChildGeneratedRootCiphertext
  ]

localBindings :: [ProductionCapabilityBinding]
localBindings =
  [ ProductionLocalRecoverRootInit
  , ProductionLocalAcknowledgeRecoveryCustody
  , ProductionLocalCaptureChildEncryptedReceipt
  , ProductionLocalPrepareChildRecoveryDelivery
  ]
