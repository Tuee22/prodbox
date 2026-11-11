{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- Test observer: follows actual heap edges and counts shared closures once.
-- It does not use the production projection's constructors or byte formulas.
module FrozenPinnedHeapGraph (observeGraphBytes, observeCellGraphBytes) where

import Control.Monad (unless)
import Data.IntMap.Strict qualified as IntMap
import GHC.Exts.Heap qualified as Heap
import GHC.Exts.Heap.Closures (closureSize)
import System.Mem.StableName (eqStableName, hashStableName, makeStableName)

observeGraphBytes :: value -> IO (Integer, Int)
observeGraphBytes = observeWith Immutable

observeCellGraphBytes :: value -> IO (Integer, Int)
observeCellGraphBytes = observeWith CounterCell

data GraphShape = Immutable | CounterCell

observeWith :: GraphShape -> value -> IO (Integer, Int)
observeWith shape root = go IntMap.empty [Heap.asBox root] 0 0
 where
  go _ [] !total !nodes = pure (total, nodes)
  go seen (box@(Heap.Box value) : remaining) !total !nodes = do
    name <- makeStableName value
    let bucket = IntMap.findWithDefault [] (hashStableName name) seen
    if any (eqStableName name) bucket
      then go seen remaining total nodes
      else do
        unless (nodes < 100000) (fail "unexpected test graph above 100000 closures")
        closure <- Heap.getBoxedClosureData box
        case closure of
          Heap.ConstrClosure {} -> pure ()
          Heap.ArrWordsClosure {} -> pure ()
          Heap.IndClosure {} -> pure ()
          Heap.MutVarClosure {} -> case shape of
            Immutable -> fail "immutable test value retained a mutable cell"
            CounterCell -> pure ()
          other -> fail ("quiescent test value retained an unexpected closure: " <> take 800 (show other))
        let seen' = IntMap.insert (hashStableName name) (name : bucket) seen
            bytes = toInteger (closureSize box) * 8
        go seen' (Heap.allClosures closure <> remaining) (total + bytes) (nodes + 1)
