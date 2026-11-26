-- | The mutation campaign's private output inventory and evidence encoding.
module Prodbox.Test.MutationOutputInventory
  ( MutationOutputLimits
  , mutationOutputLimits
  , mutationOutputLimitValues
  , MutationOutputInventory
  , MutationOutputObservation (..)
  , observeMutationOutputInventory
  , mutationWorkspaceSameMount
  , mutationOutputInventoryFingerprint
  , removeObservedMutationOutput
  ) where

import Data.Text qualified as Text
import Prodbox.Control.TreeInventory qualified as Tree
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import System.Posix.Types (Fd)

type MutationOutputLimits = Tree.TreeInventoryLimits

mutationOutputLimits :: Int -> Integer -> Int -> Int -> Maybe MutationOutputLimits
mutationOutputLimits = Tree.treeInventoryLimits

mutationOutputLimitValues :: MutationOutputLimits -> (Int, Integer, Int, Int)
mutationOutputLimitValues = Tree.treeInventoryLimitValues

newtype MutationOutputInventory = MutationOutputInventory Tree.TreeInventory
  deriving (Eq)

instance Show MutationOutputInventory where
  show (MutationOutputInventory inventory) =
    "MutationOutputInventory " ++ show (Tree.treeInventoryEntryCount inventory) ++ " entries"

data MutationOutputObservation
  = MutationOutputObserved !MutationOutputInventory
  | MutationOutputUnsafe
  | MutationOutputUnobservable
  | MutationOutputTimedOut
  deriving (Eq, Show)

observeMutationOutputInventory :: MutationOutputLimits -> Fd -> IO MutationOutputObservation
observeMutationOutputInventory limits root = do
  observed <- Tree.observeTreeInventory Tree.PrivateTree limits root
  pure $ case observed of
    Tree.TreeObserved inventory -> MutationOutputObserved (MutationOutputInventory inventory)
    Tree.TreeUnsafe -> MutationOutputUnsafe
    Tree.TreeUnobservable -> MutationOutputUnobservable
    Tree.TreeTimedOut -> MutationOutputTimedOut

mutationWorkspaceSameMount :: Fd -> Fd -> IO Bool
mutationWorkspaceSameMount = Tree.sameTreeMount

mutationOutputInventoryFingerprint :: MutationOutputInventory -> PublicEvidenceDigest
mutationOutputInventoryFingerprint (MutationOutputInventory inventory) =
  hashPublicEvidence
    (Text.pack "prodbox-mutation-output-metadata-v1\NUL" <> Tree.inventoryMetadata inventory)

removeObservedMutationOutput
  :: MutationOutputLimits -> Fd -> FilePath -> MutationOutputInventory -> IO Bool -> IO Bool
removeObservedMutationOutput limits parent name (MutationOutputInventory inventory) =
  Tree.removeObservedTree Tree.PrivateTree limits parent name inventory
