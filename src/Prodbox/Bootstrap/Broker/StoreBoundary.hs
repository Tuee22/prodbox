-- | Closed durable-store port for Bootstrap Broker custody.  Physical object
-- names are selected by the interpreter from validated role settings; callers
-- cannot provide a bucket, key, prefix, or arbitrary payload operation.
module Prodbox.Bootstrap.Broker.StoreBoundary
  ( StoreBoundaryError (..)
  , StoreVersion (..)
  , StoreReadBack (..)
  , StoreWriteResult (..)
  , BootstrapStoreBoundary (..)
  , unavailableBootstrapStoreBoundary
  )
where

import Prodbox.Bootstrap.Broker.Custody
  ( ChildCustodyState
  , ChildRecoveryState
  , RootInitState
  )
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceCasPlan
  , BootstrapFenceCasResult
  , BootstrapFenceRetireCasResult
  , BootstrapFenceRetirePlan
  , BootstrapFenceStoreObservation
  , BootstrapSessionFence
  , BootstrapStoreMutationPermit
  )
import Prodbox.Bootstrap.Broker.Model
  ( PostUnsealHandoffState
  , RootSessionState
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( SecretWorkerDurableCheckpoint
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , ChildCustodyBinding
  , ChildEncryptedReceipt
  , ChildRecoveryDelivery
  , EncryptedInitResponseReceipt
  , FinalUnlockBundle
  , ParentCustodyAcknowledgement
  , PreparedInitEnvelope
  , RootInitBinding
  , StoreVersion (..)
  , VaultStorageGeneration
  )

data StoreBoundaryError
  = BootstrapStoreUnavailable
  | BootstrapStoreCorrupt
  | BootstrapStoreBindingMismatch
  | BootstrapStoreVersionConflict
  | BootstrapStoreReadBackMismatch
  deriving (Eq, Show)

data StoreReadBack value
  = StoreObjectAbsent
  | StoreObjectPresent !StoreVersion !ArtifactDigest !value
  deriving (Eq, Show)

data StoreWriteResult value
  = StoreWriteApplied !StoreVersion !ArtifactDigest !value
  | StoreWriteConflict !(StoreReadBack value)
  deriving (Eq, Show)

-- | Every durable operation needed by the root/child custody protocols.  The
-- record is intentionally verbose: adding a new physical object family must be
-- an explicit reviewed capability, never a generic object-store escape.
data BootstrapStoreBoundary m = BootstrapStoreBoundary
  { -- The durable mutation fence is one fixed-key CAS object.  Release must
    -- preserve its generation as the vacant high-water floor; an interpreter
    -- cannot implement release as an unconditional delete.
    observeBootstrapSessionFence
      :: m (Either StoreBoundaryError BootstrapFenceStoreObservation)
  , casBootstrapSessionFence
      :: BootstrapFenceCasPlan
      -> m (Either StoreBoundaryError BootstrapFenceCasResult)
  , casRetireBootstrapSessionFence
      :: BootstrapFenceRetirePlan
      -> m (Either StoreBoundaryError BootstrapFenceRetireCasResult)
  , releaseBootstrapSessionFence
      :: BootstrapStoreMutationPermit
      -> BootstrapSessionFence
      -> m (Either StoreBoundaryError BootstrapFenceStoreObservation)
  , observeVaultStorageGeneration
      :: m (Either StoreBoundaryError RootInitBinding)
  , readRootInitJournal
      :: RootInitBinding
      -> m (Either StoreBoundaryError (StoreReadBack RootInitState))
  , createRootInitJournal
      :: BootstrapStoreMutationPermit
      -> RootInitState
      -> m (Either StoreBoundaryError (StoreWriteResult RootInitState))
  , casRootInitJournal
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> RootInitState
      -> m (Either StoreBoundaryError (StoreWriteResult RootInitState))
  , readPreparedInitEnvelope
      :: RootInitBinding
      -> m (Either StoreBoundaryError (StoreReadBack PreparedInitEnvelope))
  , createPreparedInitEnvelope
      :: BootstrapStoreMutationPermit
      -> PreparedInitEnvelope
      -> m (Either StoreBoundaryError (StoreWriteResult PreparedInitEnvelope))
  , deletePreparedInitEnvelope
      :: BootstrapStoreMutationPermit
      -> RootInitBinding
      -> StoreVersion
      -> m (Either StoreBoundaryError ())
  , readEncryptedInitResponse
      :: RootInitBinding
      -> m (Either StoreBoundaryError (StoreReadBack EncryptedInitResponseReceipt))
  , createEncryptedInitResponse
      :: BootstrapStoreMutationPermit
      -> EncryptedInitResponseReceipt
      -> m (Either StoreBoundaryError (StoreWriteResult EncryptedInitResponseReceipt))
  , readFinalUnlockBundle
      :: RootInitBinding
      -> m (Either StoreBoundaryError (StoreReadBack FinalUnlockBundle))
  , promoteFinalUnlockBundle
      :: BootstrapStoreMutationPermit
      -> EncryptedInitResponseReceipt
      -> FinalUnlockBundle
      -> m (Either StoreBoundaryError (StoreWriteResult FinalUnlockBundle))
  , readRootSessionJournal
      :: VaultStorageGeneration
      -> m (Either StoreBoundaryError (StoreReadBack RootSessionState))
  , createRootSessionJournal
      :: BootstrapStoreMutationPermit
      -> RootSessionState
      -> m (Either StoreBoundaryError (StoreWriteResult RootSessionState))
  , casRootSessionJournal
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> RootSessionState
      -> m (Either StoreBoundaryError (StoreWriteResult RootSessionState))
  , readChildEncryptedReceipt
      :: ChildCustodyBinding
      -> m (Either StoreBoundaryError (StoreReadBack ChildEncryptedReceipt))
  , createChildEncryptedReceipt
      :: BootstrapStoreMutationPermit
      -> ChildEncryptedReceipt
      -> m (Either StoreBoundaryError (StoreWriteResult ChildEncryptedReceipt))
  , parentCustodyGenerationCas
      :: BootstrapStoreMutationPermit
      -> ChildEncryptedReceipt
      -> m (Either StoreBoundaryError (StoreWriteResult ParentCustodyAcknowledgement))
  , deleteChildEncryptedReceipt
      :: BootstrapStoreMutationPermit
      -> ChildCustodyBinding
      -> StoreVersion
      -> m (Either StoreBoundaryError ())
  , readChildCustodyJournal
      :: ChildCustodyBinding
      -> m (Either StoreBoundaryError (StoreReadBack ChildCustodyState))
  , createChildCustodyJournal
      :: BootstrapStoreMutationPermit
      -> ChildCustodyState
      -> m (Either StoreBoundaryError (StoreWriteResult ChildCustodyState))
  , casChildCustodyJournal
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> ChildCustodyState
      -> m (Either StoreBoundaryError (StoreWriteResult ChildCustodyState))
  , readChildRecoveryDelivery
      :: ChildCustodyBinding
      -> m (Either StoreBoundaryError (StoreReadBack ChildRecoveryDelivery))
  , createChildRecoveryDelivery
      :: BootstrapStoreMutationPermit
      -> ChildRecoveryDelivery
      -> m (Either StoreBoundaryError (StoreWriteResult ChildRecoveryDelivery))
  , deleteChildRecoveryDelivery
      :: BootstrapStoreMutationPermit
      -> ChildCustodyBinding
      -> StoreVersion
      -> m (Either StoreBoundaryError ())
  , readChildRecoveryJournal
      :: ChildCustodyBinding
      -> m (Either StoreBoundaryError (StoreReadBack ChildRecoveryState))
  , createChildRecoveryJournal
      :: BootstrapStoreMutationPermit
      -> ChildRecoveryState
      -> m (Either StoreBoundaryError (StoreWriteResult ChildRecoveryState))
  , casChildRecoveryJournal
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> ChildRecoveryState
      -> m (Either StoreBoundaryError (StoreWriteResult ChildRecoveryState))
  , readPostUnsealHandoff
      :: RootInitBinding
      -> m (Either StoreBoundaryError (StoreReadBack PostUnsealHandoffState))
  , createPostUnsealHandoff
      :: BootstrapStoreMutationPermit
      -> PostUnsealHandoffState
      -> m (Either StoreBoundaryError (StoreWriteResult PostUnsealHandoffState))
  , casPostUnsealHandoff
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> PostUnsealHandoffState
      -> m (Either StoreBoundaryError (StoreWriteResult PostUnsealHandoffState))
  , readSecretWorkerCheckpoint
      :: m (Either StoreBoundaryError (StoreReadBack SecretWorkerDurableCheckpoint))
  , createSecretWorkerCheckpoint
      :: BootstrapStoreMutationPermit
      -> SecretWorkerDurableCheckpoint
      -> m (Either StoreBoundaryError (StoreWriteResult SecretWorkerDurableCheckpoint))
  , casSecretWorkerCheckpoint
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> SecretWorkerDurableCheckpoint
      -> m (Either StoreBoundaryError (StoreWriteResult SecretWorkerDurableCheckpoint))
  }

-- | Total fail-closed boundary for production roles whose physical object
-- store adapter is not installed and for focused tests that override only the
-- exact ports they exercise.
unavailableBootstrapStoreBoundary
  :: (Applicative m) => BootstrapStoreBoundary m
unavailableBootstrapStoreBoundary =
  BootstrapStoreBoundary
    { observeBootstrapSessionFence = unavailable
    , casBootstrapSessionFence = \_ -> unavailable
    , casRetireBootstrapSessionFence = \_ -> unavailable
    , releaseBootstrapSessionFence = \_ _ -> unavailable
    , observeVaultStorageGeneration = unavailable
    , readRootInitJournal = \_ -> unavailable
    , createRootInitJournal = \_ _ -> unavailable
    , casRootInitJournal = \_ _ _ -> unavailable
    , readPreparedInitEnvelope = \_ -> unavailable
    , createPreparedInitEnvelope = \_ _ -> unavailable
    , deletePreparedInitEnvelope = \_ _ _ -> unavailable
    , readEncryptedInitResponse = \_ -> unavailable
    , createEncryptedInitResponse = \_ _ -> unavailable
    , readFinalUnlockBundle = \_ -> unavailable
    , promoteFinalUnlockBundle = \_ _ _ -> unavailable
    , readRootSessionJournal = \_ -> unavailable
    , createRootSessionJournal = \_ _ -> unavailable
    , casRootSessionJournal = \_ _ _ -> unavailable
    , readChildEncryptedReceipt = \_ -> unavailable
    , createChildEncryptedReceipt = \_ _ -> unavailable
    , parentCustodyGenerationCas = \_ _ -> unavailable
    , deleteChildEncryptedReceipt = \_ _ _ -> unavailable
    , readChildCustodyJournal = \_ -> unavailable
    , createChildCustodyJournal = \_ _ -> unavailable
    , casChildCustodyJournal = \_ _ _ -> unavailable
    , readChildRecoveryDelivery = \_ -> unavailable
    , createChildRecoveryDelivery = \_ _ -> unavailable
    , deleteChildRecoveryDelivery = \_ _ _ -> unavailable
    , readChildRecoveryJournal = \_ -> unavailable
    , createChildRecoveryJournal = \_ _ -> unavailable
    , casChildRecoveryJournal = \_ _ _ -> unavailable
    , readPostUnsealHandoff = \_ -> unavailable
    , createPostUnsealHandoff = \_ _ -> unavailable
    , casPostUnsealHandoff = \_ _ _ -> unavailable
    , readSecretWorkerCheckpoint = unavailable
    , createSecretWorkerCheckpoint = \_ _ -> unavailable
    , casSecretWorkerCheckpoint = \_ _ _ -> unavailable
    }
 where
  unavailable = pure (Left BootstrapStoreUnavailable)
