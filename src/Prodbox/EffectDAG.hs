module Prodbox.EffectDAG
    ( EffectDAG (..),
      EffectNode (..),
      fromRootIds,
      transitiveClosureIds,
    )
where

import Control.Monad
    ( foldM,
    )
import Data.List
    ( sort,
    )
import qualified Data.Map.Strict as Map
import Data.Map.Strict
    ( Map,
    )
import qualified Data.Set as Set
import Data.Set
    ( Set,
    )
import Prodbox.Effect
    ( Effect,
    )

data EffectNode = EffectNode
    { effectNodeId :: String,
      effectNodeDescription :: String,
      effectNodePrerequisites :: [String],
      effectNodeEffect :: Effect
    }
    deriving (Eq, Show)

data EffectDAG = EffectDAG
    { effectDagRoots :: [String],
      effectDagNodes :: Map String EffectNode
    }
    deriving (Eq, Show)

fromRootIds :: [String] -> Map String EffectNode -> Either String EffectDAG
fromRootIds rootIds registry = do
    closureIds <- transitiveClosureIds rootIds registry
    let nodeIds = Set.fromList closureIds
    pure
        EffectDAG
            { effectDagRoots = sort (orderedUnique rootIds),
              effectDagNodes = Map.filterWithKey (\nodeId _ -> Set.member nodeId nodeIds) registry
            }

transitiveClosureIds :: [String] -> Map String EffectNode -> Either String [String]
transitiveClosureIds effectIds registry = do
    visited <- foldM visit Set.empty effectIds
    pure (sort (Set.toList visited))
  where
    visit :: Set String -> String -> Either String (Set String)
    visit visited effectId
        | Set.member effectId visited = Right visited
        | otherwise =
            case Map.lookup effectId registry of
                Nothing -> Left ("Missing effect node in registry: " ++ effectId)
                Just node -> do
                    expandedVisited <- foldM visit (Set.insert effectId visited) (effectNodePrerequisites node)
                    Right expandedVisited

orderedUnique :: [String] -> [String]
orderedUnique = go Set.empty
  where
    go :: Set String -> [String] -> [String]
    go _ [] = []
    go visited (value : remaining)
        | Set.member value visited = go visited remaining
        | otherwise = value : go (Set.insert value visited) remaining
