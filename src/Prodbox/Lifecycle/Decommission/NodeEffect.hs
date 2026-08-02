{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the destroy-and-read-back seam that binds a decommission
-- 'DecommissionNode' to a real destructive operation.
--
-- Both halves receive the stable node/attempt identity from the durable intent.
-- This is load-bearing during recovery: the runner can authoritatively re-observe
-- an intent whose response was lost and, only when residue is still present,
-- retry the exact same idempotent attempt rather than minting a second mutation.
module Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeObservation (..)
  , NodeOperation (..)
  , classifyReadBack
  , classifyNodeObservation
  , destroyNodeOperation
  , observeNodeOperation
  , runNodeOperation
  , DecommissionNodeInterpreter (..)
  , DecommissionOperationRegistry (..)
  , SesConsumerQuiescenceCapability (..)
  , SesProviderStackCapability (..)
  , SesSmtpIamCapability (..)
  , TargetGenerationTombstoneCapability (..)
  , RetainedCustodyTombstoneCapability (..)
  , TlsRetainedObjectsCapability (..)
  , TlsRetentionIdentityCapability (..)
  , BackupObjectsIdentityCapability (..)
  , BackupAllPrefixesAbsentCapability (..)
  , SharedObjectBucketCapability (..)
  , ProductionDecommissionCapabilities (..)
  , decommissionRegistryFromProductionCapabilities
  , decommissionInterpreterFromRegistry
  , destroyDecommissionNode
  , observeDecommissionNode
  , runDecommissionNode
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame (FrameAttemptId, FrameNodeId)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode
      ( BackupObjects
      , BackupPrefixAbsenceProof
      , RetainedCustody
      , SesConsumerQuiescence
      , SesProviderStack
      , SesSmtpIam
      , SharedObjectBucket
      , TargetGeneration
      , TlsRetainedObjects
      , TlsRetentionIdentity
      )
  , DecommissionTargetGeneration
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  , renderResidueStatus
  )

-- | A serialisable projection of one authoritative external read-back.
-- Presence and unavailability remain distinct because neither may be recoded as
-- absence in the external receipt.
data NodeObservation
  = NodeObservedAbsent
  | NodeObservedPresent !Text
  | NodeObservationUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | One node's destructive operation.  The stable identities are explicit
-- arguments at the effect boundary, so an interpreter cannot accidentally use a
-- process-local or freshly generated idempotency key while resuming.
data NodeOperation m = NodeOperation
  { nodeDestroy :: FrameNodeId -> FrameAttemptId -> m (Either Text ())
  , nodeReadBack :: FrameNodeId -> FrameAttemptId -> m ResidueStatus
  }

-- | Classify a provider-shaped read-back. Only a positively observed absence
-- confirms the destroy.
classifyReadBack :: ResidueStatus -> Either Text ()
classifyReadBack = classifyNodeObservation . nodeObservationOf

-- | Classify the receipt-shaped observation vocabulary.
classifyNodeObservation :: NodeObservation -> Either Text ()
classifyNodeObservation observation = case observation of
  NodeObservedAbsent -> Right ()
  NodeObservedPresent detail -> Left ("read-back did not confirm absence: " <> detail)
  NodeObservationUnavailable detail -> Left ("read-back did not confirm absence: " <> detail)

nodeObservationOf :: ResidueStatus -> NodeObservation
nodeObservationOf status = case status of
  ResidueAbsent -> NodeObservedAbsent
  ResiduePresent _ -> NodeObservedPresent rendered
  ResidueUnreachable _ -> NodeObservationUnavailable rendered
 where
  rendered = Text.pack (renderResidueStatus status)

-- | Invoke only the destructive half with the identity from the intent frame.
destroyNodeOperation
  :: NodeOperation m
  -> FrameNodeId
  -> FrameAttemptId
  -> m (Either Text ())
destroyNodeOperation operation = nodeDestroy operation

-- | Invoke only the authoritative observation half with that same identity.
observeNodeOperation
  :: (Functor m)
  => NodeOperation m
  -> FrameNodeId
  -> FrameAttemptId
  -> m NodeObservation
observeNodeOperation operation nodeId attemptId =
  nodeObservationOf <$> nodeReadBack operation nodeId attemptId

-- | Run one fresh operation: destroy, then authoritatively re-observe. Recovery
-- uses 'observeNodeOperation' separately before deciding whether this is safe.
runNodeOperation
  :: (Monad m)
  => NodeOperation m
  -> FrameNodeId
  -> FrameAttemptId
  -> m (Either Text ())
runNodeOperation operation nodeId attemptId = do
  destroyed <- destroyNodeOperation operation nodeId attemptId
  case destroyed of
    Left detail -> pure (Left detail)
    Right () -> classifyNodeObservation <$> observeNodeOperation operation nodeId attemptId

-- | Total mapping from a manifest node to its registered operation.
newtype DecommissionNodeInterpreter m = DecommissionNodeInterpreter
  { nodeOperationFor :: DecommissionNode -> NodeOperation m
  }

-- | Compile-time-total registry for every constructor in the closed manifest
-- vocabulary.  There is no catch-all operation: adding a new node makes the
-- mapping below non-exhaustive until its production boundary is supplied.
data DecommissionOperationRegistry m = DecommissionOperationRegistry
  { sesConsumerQuiescenceOperation :: !(NodeOperation m)
  , sesProviderStackOperation :: !(NodeOperation m)
  , sesSmtpIamOperation :: !(NodeOperation m)
  , targetGenerationOperation :: !(Text -> DecommissionTargetGeneration -> NodeOperation m)
  , retainedCustodyOperation :: !(NodeOperation m)
  , tlsRetainedObjectsOperation :: !(NodeOperation m)
  , tlsRetentionIdentityOperation :: !(NodeOperation m)
  , backupPrefixAbsenceProofOperation :: !(NodeOperation m)
  , backupObjectsOperation :: !(NodeOperation m)
  , sharedObjectBucketOperation :: !(NodeOperation m)
  }

-- The production composition uses distinct capability wrappers rather than a
-- bag of interchangeable 'NodeOperation' values. This keeps each exact
-- provider/Agent/store family visible at the wiring boundary while retaining a
-- small, testable destroy/read-back algebra below it.

-- | Stop every registered SMTP consumer and authoritatively read back
-- quiescence before either SES family may be deleted.
newtype SesConsumerQuiescenceCapability m = SesConsumerQuiescenceCapability
  { runSesConsumerQuiescenceCapability :: NodeOperation m
  }

-- | Delete and read back the registered non-credential SES/S3 provider family.
newtype SesProviderStackCapability m = SesProviderStackCapability
  { runSesProviderStackCapability :: NodeOperation m
  }

-- | Delete and read back the disjoint external SMTP key/identity/policy family.
newtype SesSmtpIamCapability m = SesSmtpIamCapability
  { runSesSmtpIamCapability :: NodeOperation m
  }

-- | Ask the still-live Target Agent to tombstone and read back the exact signed
-- target generation named by the manifest.
newtype TargetGenerationTombstoneCapability m = TargetGenerationTombstoneCapability
  { runTargetGenerationTombstoneCapability
      :: Text
      -> DecommissionTargetGeneration
      -> NodeOperation m
  }

-- | Tombstone and read back the distinct retained-home custody source only
-- after every selected target generation is absent.
newtype RetainedCustodyTombstoneCapability m = RetainedCustodyTombstoneCapability
  { runRetainedCustodyTombstoneCapability :: NodeOperation m
  }

-- | Delete and read back every version under the registered TLS prefixes,
-- without deleting their shared bucket.
newtype TlsRetainedObjectsCapability m = TlsRetainedObjectsCapability
  { runTlsRetainedObjectsCapability :: NodeOperation m
  }

-- | Delete and read back the disjoint TLS access key/identity/policy.
newtype TlsRetentionIdentityCapability m = TlsRetentionIdentityCapability
  { runTlsRetentionIdentityCapability :: NodeOperation m
  }

-- | Delete and read back Authority backup objects/versions, prefix,
-- generation/key, and identity/policy after both TLS nodes are absent.
newtype BackupObjectsIdentityCapability m = BackupObjectsIdentityCapability
  { runBackupObjectsIdentityCapability :: NodeOperation m
  }

-- | Authoritatively observe that every registered prefix in the shared bucket
-- is absent. This is deliberately read-only: production composition cannot
-- smuggle an additional deletion into the proof node.
newtype BackupAllPrefixesAbsentCapability m = BackupAllPrefixesAbsentCapability
  { observeBackupAllPrefixesAbsent
      :: FrameNodeId
      -> FrameAttemptId
      -> m ResidueStatus
  }

-- | Delete and read back the shared object bucket after the all-prefix proof.
newtype SharedObjectBucketCapability m = SharedObjectBucketCapability
  { runSharedObjectBucketCapability :: NodeOperation m
  }

-- | Exact capability inventory required by the production standalone runner.
-- There is no optional or fallback field and no generic provider operation.
data ProductionDecommissionCapabilities m = ProductionDecommissionCapabilities
  { productionSesConsumerQuiescence :: !(SesConsumerQuiescenceCapability m)
  , productionSesProviderStack :: !(SesProviderStackCapability m)
  , productionSesSmtpIam :: !(SesSmtpIamCapability m)
  , productionTargetGenerationTombstone :: !(TargetGenerationTombstoneCapability m)
  , productionRetainedCustodyTombstone :: !(RetainedCustodyTombstoneCapability m)
  , productionTlsRetainedObjects :: !(TlsRetainedObjectsCapability m)
  , productionTlsRetentionIdentity :: !(TlsRetentionIdentityCapability m)
  , productionBackupObjectsIdentity :: !(BackupObjectsIdentityCapability m)
  , productionBackupAllPrefixesAbsent :: !(BackupAllPrefixesAbsentCapability m)
  , productionSharedObjectBucket :: !(SharedObjectBucketCapability m)
  }

-- | Lower the role-separated production capability inventory into the closed
-- manifest registry. The all-prefix proof receives a no-op destructive half and
-- only its injected authoritative observer can decide absence.
decommissionRegistryFromProductionCapabilities
  :: (Applicative m)
  => ProductionDecommissionCapabilities m
  -> DecommissionOperationRegistry m
decommissionRegistryFromProductionCapabilities capabilities =
  DecommissionOperationRegistry
    { sesConsumerQuiescenceOperation =
        runSesConsumerQuiescenceCapability (productionSesConsumerQuiescence capabilities)
    , sesProviderStackOperation =
        runSesProviderStackCapability (productionSesProviderStack capabilities)
    , sesSmtpIamOperation =
        runSesSmtpIamCapability (productionSesSmtpIam capabilities)
    , targetGenerationOperation =
        runTargetGenerationTombstoneCapability (productionTargetGenerationTombstone capabilities)
    , retainedCustodyOperation =
        runRetainedCustodyTombstoneCapability (productionRetainedCustodyTombstone capabilities)
    , tlsRetainedObjectsOperation =
        runTlsRetainedObjectsCapability (productionTlsRetainedObjects capabilities)
    , tlsRetentionIdentityOperation =
        runTlsRetentionIdentityCapability (productionTlsRetentionIdentity capabilities)
    , backupPrefixAbsenceProofOperation =
        readOnlyAbsenceProof (productionBackupAllPrefixesAbsent capabilities)
    , backupObjectsOperation =
        runBackupObjectsIdentityCapability (productionBackupObjectsIdentity capabilities)
    , sharedObjectBucketOperation =
        runSharedObjectBucketCapability (productionSharedObjectBucket capabilities)
    }
 where
  readOnlyAbsenceProof proof =
    NodeOperation
      { nodeDestroy = \_ _ -> pure (Right ())
      , nodeReadBack = observeBackupAllPrefixesAbsent proof
      }

-- | Build the only production-shaped interpreter from the total registry.
decommissionInterpreterFromRegistry
  :: DecommissionOperationRegistry m
  -> DecommissionNodeInterpreter m
decommissionInterpreterFromRegistry registry =
  DecommissionNodeInterpreter (operationForNode registry)

operationForNode
  :: DecommissionOperationRegistry m
  -> DecommissionNode
  -> NodeOperation m
operationForNode registry node = case node of
  SesConsumerQuiescence -> sesConsumerQuiescenceOperation registry
  SesProviderStack -> sesProviderStackOperation registry
  SesSmtpIam -> sesSmtpIamOperation registry
  TargetGeneration target generation -> targetGenerationOperation registry target generation
  RetainedCustody -> retainedCustodyOperation registry
  TlsRetainedObjects -> tlsRetainedObjectsOperation registry
  TlsRetentionIdentity -> tlsRetentionIdentityOperation registry
  BackupPrefixAbsenceProof -> backupPrefixAbsenceProofOperation registry
  BackupObjects -> backupObjectsOperation registry
  SharedObjectBucket -> sharedObjectBucketOperation registry

destroyDecommissionNode
  :: DecommissionNodeInterpreter m
  -> DecommissionNode
  -> FrameNodeId
  -> FrameAttemptId
  -> m (Either Text ())
destroyDecommissionNode interpreter node =
  destroyNodeOperation (nodeOperationFor interpreter node)

observeDecommissionNode
  :: (Functor m)
  => DecommissionNodeInterpreter m
  -> DecommissionNode
  -> FrameNodeId
  -> FrameAttemptId
  -> m NodeObservation
observeDecommissionNode interpreter node =
  observeNodeOperation (nodeOperationFor interpreter node)

-- | Convenience composition for the non-recovery graph executor.
runDecommissionNode
  :: (Monad m)
  => DecommissionNodeInterpreter m
  -> DecommissionNode
  -> FrameNodeId
  -> FrameAttemptId
  -> m (Either Text ())
runDecommissionNode interpreter node =
  runNodeOperation (nodeOperationFor interpreter node)
