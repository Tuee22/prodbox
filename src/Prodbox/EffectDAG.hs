module Prodbox.EffectDAG
  ( EffectDAG (..)
  , EffectNode (..)
  , fromRootIds
  , transitiveClosureIds
  )
where

import Control.Monad
  ( foldM
  )
import Data.List
  ( intercalate
  , sortBy
  )
import Data.Map.Strict
  ( Map
  )
import Data.Map.Strict qualified as Map
import Data.Ord
  ( comparing
  )
import Data.Set
  ( Set
  )
import Data.Set qualified as Set
import Prodbox.Effect
  ( Effect
  )
import Prodbox.PrerequisiteId
  ( PrerequisiteId
  , prerequisiteIdText
  )

-- | Sprint 5.6: 'EffectNode' is keyed by the typed 'PrerequisiteId' rather
-- than a raw @String@, so identifiers are exhaustively matched. The
-- registry and the ad-hoc lifecycle nodes both build typed nodes; the
-- interpreter surfaces 'prerequisiteIdText' for operator-facing rendering.
data EffectNode = EffectNode
  { effectNodeId :: PrerequisiteId
  , effectNodeDescription :: String
  , effectNodeRemedyHint :: String
  , effectNodePrerequisites :: [PrerequisiteId]
  , effectNodeEffect :: Effect
  }
  deriving (Eq, Show)

data EffectDAG = EffectDAG
  { effectDagRoots :: [PrerequisiteId]
  , effectDagNodes :: Map PrerequisiteId EffectNode
  }
  deriving (Eq, Show)

fromRootIds :: [PrerequisiteId] -> Map PrerequisiteId EffectNode -> Either String EffectDAG
fromRootIds rootIds registry = do
  closureIds <- transitiveClosureIds rootIds registry
  let nodeIds = Set.fromList closureIds
  pure
    EffectDAG
      { effectDagRoots = sortById (orderedUnique rootIds)
      , effectDagNodes = Map.filterWithKey (\nodeId _ -> Set.member nodeId nodeIds) registry
      }

transitiveClosureIds
  :: [PrerequisiteId] -> Map PrerequisiteId EffectNode -> Either String [PrerequisiteId]
transitiveClosureIds effectIds registry = do
  visited <- foldM (visit []) Set.empty effectIds
  pure (sortById (Set.toList visited))
 where
  -- `ancestors` is the current DFS recursion stack (root → current). A node that appears in
  -- its own ancestor path is a back-edge: rejected at expansion time so a cyclic registry can
  -- never produce an `EffectDAG`. `visited` short-circuits already-resolved sub-DAGs, but it is
  -- never relied on to mask a cycle — the recursion-stack check fires before a node is marked
  -- visited.
  visit
    :: [PrerequisiteId] -> Set PrerequisiteId -> PrerequisiteId -> Either String (Set PrerequisiteId)
  visit ancestors visited effectId
    | effectId `elem` ancestors =
        Left (cycleErrorMessage (reverse (effectId : ancestors)))
    | Set.member effectId visited = Right visited
    | otherwise =
        case Map.lookup effectId registry of
          Nothing -> Left ("Missing effect node in registry: " ++ prerequisiteIdText effectId)
          Just node -> do
            expandedVisited <-
              foldM
                (visit (effectId : ancestors))
                (Set.insert effectId visited)
                (effectNodePrerequisites node)
            Right expandedVisited

  cycleErrorMessage :: [PrerequisiteId] -> String
  cycleErrorMessage path =
    "Prerequisite cycle detected: " ++ intercalate " -> " (map prerequisiteIdText path)

-- | Order identifiers by their stable display string so the surfaced
-- ordering (interpreter ready set, DAG roots) stays the deterministic
-- snake_case ordering callers and goldens already depend on, independent
-- of the 'PrerequisiteId' constructor declaration order.
sortById :: [PrerequisiteId] -> [PrerequisiteId]
sortById = sortBy (comparing prerequisiteIdText)

orderedUnique :: [PrerequisiteId] -> [PrerequisiteId]
orderedUnique = go Set.empty
 where
  go :: Set PrerequisiteId -> [PrerequisiteId] -> [PrerequisiteId]
  go _ [] = []
  go visited (value : remaining)
    | Set.member value visited = go visited remaining
    | otherwise = value : go (Set.insert value visited) remaining
