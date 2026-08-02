{-# LANGUAGE DerivingStrategies #-}

-- | Fenced garbage collection for secret-bearing legacy Pulumi checkpoint
-- versions. Primary and mandatory-backup copies are exact, finite values.
module Prodbox.Ses.Workflow.LegacyCheckpointGc
  ( LegacyBlobCopy (..)
  , LegacyBlobObservation (..)
  , LegacyCheckpointGcInput (..)
  , LegacyCheckpointGcDecision (..)
  , LegacyCheckpointGcRefusal (..)
  , decideLegacyCheckpointGc
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

data LegacyBlobCopy
  = LegacyPrimaryVersion !Text
  | LegacyBackupVersion !Text
  deriving stock (Eq, Ord, Show)

data LegacyBlobObservation
  = LegacyBlobPresent
  | LegacyBlobAbsent
  | LegacyBlobUnobservable !Text
  deriving stock (Eq, Show)

data LegacyCheckpointGcInput = LegacyCheckpointGcInput
  { legacyGcRollbackWindowClosed :: !Bool
  , legacyGcFenceHeld :: !Bool
  , legacyGcExpectedCopies :: !(Set LegacyBlobCopy)
  , legacyGcLiveReferences :: !(Set LegacyBlobCopy)
  , legacyGcObservations :: !(Map LegacyBlobCopy LegacyBlobObservation)
  }
  deriving stock (Eq, Show)

data LegacyCheckpointGcDecision
  = DeleteLegacyCheckpointCopies !(Set LegacyBlobCopy)
  | CommitLegacyCheckpointGcReceipt !(Set LegacyBlobCopy)
  deriving stock (Eq, Show)

data LegacyCheckpointGcRefusal
  = LegacyRollbackWindowOpen
  | LegacyGcFenceMissing
  | LegacyCheckpointStillReferenced !(Set LegacyBlobCopy)
  | LegacyCheckpointObservationIncomplete !(Set LegacyBlobCopy)
  | LegacyCheckpointCopyUnobservable !LegacyBlobCopy !Text
  | LegacyCheckpointPartialDeletion !(Set LegacyBlobCopy)
  deriving stock (Eq, Show)

decideLegacyCheckpointGc
  :: LegacyCheckpointGcInput
  -> Either LegacyCheckpointGcRefusal LegacyCheckpointGcDecision
decideLegacyCheckpointGc input
  | not (legacyGcRollbackWindowClosed input) = Left LegacyRollbackWindowOpen
  | not (legacyGcFenceHeld input) = Left LegacyGcFenceMissing
  | not (Set.null references) = Left (LegacyCheckpointStillReferenced references)
  | not (Set.null missing) = Left (LegacyCheckpointObservationIncomplete missing)
  | Just (copy, detail) <- firstUnobservable = Left (LegacyCheckpointCopyUnobservable copy detail)
  | present == expected = Right (DeleteLegacyCheckpointCopies expected)
  | Set.null present = Right (CommitLegacyCheckpointGcReceipt expected)
  | otherwise = Left (LegacyCheckpointPartialDeletion present)
 where
  expected = legacyGcExpectedCopies input
  references = legacyGcLiveReferences input `Set.intersection` expected
  observed = legacyGcObservations input
  missing = expected `Set.difference` Map.keysSet observed
  present = Map.keysSet (Map.filter (== LegacyBlobPresent) observed)
  firstUnobservable =
    case [ (copy, detail)
         | (copy, LegacyBlobUnobservable detail) <- Map.toAscList observed
         , copy `Set.member` expected
         ] of
      [] -> Nothing
      value : _ -> Just value
