-- | Bind a real managed-host retirement observation to a mutation workspace.
-- This does not prove that all mutation workers used the recorded family.
module Prodbox.Test.MutationWorkerSettlement
  ( MutationHostObservationError (..)
  , MutationHostObservationOutcome (..)
  , withMutationHostRetirementObservation
  , retireMutationOutputAfterHostSettlement
  ) where

import Control.Exception (mask)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import Prodbox.Subprocess.HostControllerInputs
  ( HostControllerSubmissionRecord
  , hostControllerSubmissionKey
  , hostControllerSubmissionKind
  )
import Prodbox.Subprocess.HostOperationRetirement
  ( HostOperationRetirement
  , RetirementError
  , hostOperationRetirementDeadline
  , hostOperationRetirementMatches
  , verifyHostOperationRetirementBefore
  , withHostOperationRetirementBorrow
  )
import Prodbox.Subprocess.SystemdIdentity (HostControllerKind (MutationController))
import Prodbox.Test.MutationOutputInventory (MutationOutputLimits)
import Prodbox.Test.MutationSnapshot (MutationSnapshot)
import Prodbox.Test.MutationSnapshotWrite (MutationSnapshotRootIdentity)
import Prodbox.Test.MutationWorkspace (MutationWorkspaceOutcome, beginMutationOutputRetirement)
import Prodbox.Test.MutationWorkspaceIntent (mutationWorkspaceWorkerKey)

data MutationHostObservationError
  = MutationHostObservationInvalidBinding
  | MutationHostObservationRecordMismatch
  | MutationHostObservationHostRefused !RetirementError
  deriving (Eq, Show)

data MutationHostObservationOutcome value
  = MutationHostObservationRefused !MutationHostObservationError
  | MutationHostObservationConfirmed !value
  | MutationHostObservationChangedAfter !value !MutationHostObservationError
  deriving (Eq, Show)

-- | Borrow the real host retirement observer, bind its exact submission key to
-- the snapshot birth, and recheck it after the callback. This observes only
-- the recorded host family. The caller must separately prove launch admission,
-- all-worker coverage, workspace identity, isolation and cleanup; this is not
-- permission to execute a mutant or remove its workspace.
withMutationHostRetirementObservation
  :: Word64
  -> HostOperationRetirement
  -> HostControllerSubmissionRecord
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> (HostOperationRetirement -> IO value)
  -> IO (MutationHostObservationOutcome value)
withMutationHostRetirementObservation deadline owner record operation snapshot rootIdentity action =
  case mutationWorkspaceWorkerKey operation snapshot rootIdentity of
    Nothing -> pure (MutationHostObservationRefused MutationHostObservationInvalidBinding)
    Just key
      | hostControllerSubmissionKind record /= MutationController
          || hostControllerSubmissionKey record /= key
          || not (hostOperationRetirementMatches owner record) ->
          pure (MutationHostObservationRefused MutationHostObservationRecordMismatch)
      | otherwise -> do
          returned <- newIORef Nothing
          let ending = min deadline (hostOperationRetirementDeadline owner)
          result <- withHostOperationRetirementBorrow ending owner $ \borrowed -> do
            value <- mask $ \restore -> do
              resultValue <- restore (action borrowed)
              writeIORef returned (Just resultValue)
              pure resultValue
            final <- verifyHostOperationRetirementBefore ending borrowed
            pure $ case final of
              Right () -> MutationHostObservationConfirmed value
              Left failure -> MutationHostObservationChangedAfter value (MutationHostObservationHostRefused failure)
          case result of
            Right outcome -> pure outcome
            Left failure -> do
              value <- readIORef returned
              let cause = MutationHostObservationHostRefused failure
              pure
                (maybe (MutationHostObservationRefused cause) (`MutationHostObservationChangedAfter` cause) value)

-- | Record the output transition while a matching real host-family retirement
-- observation is held. The caller must hold and verify the source birth and
-- establish all-worker coverage and writer/alias exclusion independently.
-- This does not remove output or prove its contents.
retireMutationOutputAfterHostSettlement
  :: Word64
  -> HostOperationRetirement
  -> HostControllerSubmissionRecord
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> MutationOutputLimits
  -> String
  -> FilePath
  -> String
  -> MutationSnapshot
  -> IO (MutationHostObservationOutcome (MutationWorkspaceOutcome ()))
retireMutationOutputAfterHostSettlement deadline owner record sourceOperation sourceSnapshot sourceIdentity limits checkpoint outputProject outputOperation outputSnapshot =
  withMutationHostRetirementObservation
    deadline
    owner
    record
    sourceOperation
    sourceSnapshot
    sourceIdentity
    $ \borrowed ->
      beginMutationOutputRetirement
        limits
        (hostControllerSubmissionKey record)
        checkpoint
        (either (const False) (const True) <$> verifyHostOperationRetirementBefore deadline borrowed)
        outputProject
        outputOperation
        outputSnapshot
