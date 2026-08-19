{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The single production dispatcher for cloud-owned teardown operations.
-- The runtime composes existing lifecycle interpreters; it is not a second
-- execution engine.  A single registered-target interpreter is installed in
-- both components that need Provider observations, so checkpoint recovery,
-- EKS drain, and registered reconciliation cannot accidentally address
-- different Provider boundaries.
module Prodbox.Lifecycle.Teardown.CloudRuntime
  ( CloudRuntime
  , mkCloudRuntime
  , executeCloudOperation
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.AwsStackReaderInterpreter
import Prodbox.Lifecycle.Teardown.EksTeardownExecutor
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Program

-- | Closed component inventory for the cloud portion of lifecycle teardown.
-- Construction is intentionally opaque: callers cannot retain checkpoint or
-- EKS components wired to a different registered-target interpreter.
data CloudRuntime m = CloudRuntime
  { internalCloudRegisteredTargetInterpreter
      :: !(AwsRegisteredTargetInterpreter m)
  , internalCloudCheckpointInterpreter :: !(AwsCheckpointInterpreter m)
  , internalCloudStackReaderInterpreter :: !(AwsStackReaderInterpreter m)
  , internalCloudEksTeardownExecutor :: !(EksTeardownExecutor m)
  }

-- | Construct one cloud runtime and normalize every Provider-observing
-- component to the same registered-target interpreter.
mkCloudRuntime
  :: AwsRegisteredTargetInterpreter m
  -> AwsCheckpointInterpreter m
  -> AwsStackReaderInterpreter m
  -> EksTeardownExecutor m
  -> CloudRuntime m
mkCloudRuntime registered checkpoint stackReader eksExecutor =
  CloudRuntime
    { internalCloudRegisteredTargetInterpreter = registered
    , internalCloudCheckpointInterpreter =
        checkpoint
          { awsCheckpointRegisteredTargetInterpreter = registered
          }
    , internalCloudStackReaderInterpreter = stackReader
    , internalCloudEksTeardownExecutor =
        eksExecutor
          { eksTeardownRegisteredTargetInterpreter = registered
          }
    }

-- | Dispatch exactly the cloud-owned operation universe.  'Nothing' means
-- the closed operation belongs to recovery-plane, audit/report, local
-- foundation, or total-decommission handling.  A component that declines an
-- operation claimed here is converted to a refusal instead of being allowed
-- to disappear into another fallback interpreter.
executeCloudOperation
  :: (Monad m)
  => CloudRuntime m
  -> TeardownExecutionContext surface
  -> TeardownOperation surface
  -> m (Maybe (TeardownNodeResult surface))
executeCloudOperation runtime context operation = case operation of
  ObserveRegisteredTarget target ->
    fmap
      ( Just
          . either
            (componentError "registered-target observe")
            TeardownExactResourceObservation
      )
      ( observeAwsRegisteredTarget
          (internalCloudRegisteredTargetInterpreter runtime)
          context
          target
      )
  ReconcileRegisteredTargetAbsent target ->
    fmap
      ( Just
          . either
            (componentError "registered-target reconcile")
            TeardownRegisteredTargetReconcile
      )
      ( reconcileAwsRegisteredTargetAbsent
          (internalCloudRegisteredTargetInterpreter runtime)
          context
          target
      )
  ReadBackRegisteredTargetAbsent target ->
    fmap
      ( Just
          . either
            (componentError "registered-target read-back")
            TeardownExactResourceObservation
      )
      ( readBackAwsRegisteredTargetAbsent
          (internalCloudRegisteredTargetInterpreter runtime)
          context
          target
      )
  ObserveStackCheckpointPair _ -> runCheckpoint
  ReconcileStackCheckpointRestore _ -> runCheckpoint
  ReadBackStackCheckpointRecovery _ -> runCheckpoint
  RetireStackCheckpointPair _ -> runCheckpoint
  ReadBackStackCheckpointRetirement _ -> runCheckpoint
  CommitAwsStackReaderBundle _ -> runStackReader
  ReadBackAwsStackReaderBundle _ -> runStackReader
  CommitEksDrainIntent _ -> runEks
  ReadBackEksDrainIntent _ -> runEks
  DrainEksKubernetesResources _ -> runEks
  ReadBackEksKubernetesDrain _ -> runEks
  EstablishRecoveryPlane _ -> pure Nothing
  ReadBackRecoveryPlane _ -> pure Nothing
  ObserveRecoveryPlaneDisposition _ -> pure Nothing
  AuditCascadeEscapes -> pure Nothing
  CommitCascadePreUninstallReport -> pure Nothing
  ReadBackCascadePreUninstallReport -> pure Nothing
  UninstallCascadeLocalFoundation -> pure Nothing
  ReadBackCascadeLocalAbsence -> pure Nothing
  CommitCascadeCompletion -> pure Nothing
  ReadBackCascadeCompletion -> pure Nothing
  UninstallLocalOnlyFoundation -> pure Nothing
  ReadBackLocalOnlyAbsence -> pure Nothing
  CommitLocalOnlyCompletion -> pure Nothing
  ReadBackLocalOnlyCompletion -> pure Nothing
  RevokeOperationalCredential _ -> pure Nothing
  ReadBackOperationalCredentialRevocation _ -> pure Nothing
  CommitOrdinarySurfaceReport -> pure Nothing
  ReadBackOrdinarySurfaceReport -> pure Nothing
  AuditTotalDecommissionEscapes -> pure Nothing
  ObserveExternalDecommissionReceipt -> pure Nothing
  UninstallDecommissionLocalFoundation -> pure Nothing
  ReadBackDecommissionLocalAbsence -> pure Nothing
  ApplyDecommissionLocalDataDisposition -> pure Nothing
  ReadBackDecommissionLocalDataDisposition -> pure Nothing
  CommitDecommissionTerminalReceipt -> pure Nothing
  ReadBackDecommissionTerminalReceipt -> pure Nothing
 where
  runCheckpoint = do
    interpreted <-
      executeAwsCheckpointOperation
        (internalCloudCheckpointInterpreter runtime)
        context
        operation
    pure
      ( Just
          ( case interpreted of
              Left err -> componentError "checkpoint" err
              Right Nothing -> componentDeclined "checkpoint" operation
              Right (Just result) -> result
          )
      )

  runStackReader = do
    interpreted <-
      executeAwsStackReaderOperation
        (internalCloudStackReaderInterpreter runtime)
        context
        operation
    pure
      ( Just
          ( case interpreted of
              Nothing -> componentDeclined "stack-reader" operation
              Just result -> result
          )
      )

  runEks = do
    interpreted <-
      executeEksTeardownOperation
        (internalCloudEksTeardownExecutor runtime)
        context
        operation
    pure
      ( Just
          ( case interpreted of
              Nothing -> componentDeclined "EKS teardown" operation
              Just result -> result
          )
      )

componentError :: (Show err) => Text -> err -> TeardownNodeResult surface
componentError component err =
  TeardownNodeRefused
    (bounded (component <> " component refused: " <> Text.pack (show err)))

componentDeclined
  :: Text -> TeardownOperation surface -> TeardownNodeResult surface
componentDeclined component operation =
  TeardownNodeRefused
    ( bounded
        ( component
            <> " component declined owned operation "
            <> teardownOperationTag operation
        )
    )

bounded :: Text -> Text
bounded = Text.take 4096
