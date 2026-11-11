{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- Test observer: follows actual heap edges and counts shared closures once.
-- It does not use the production projection's constructors or byte formulas.
module PinnedHeapGraph
  ( observeGraphBytes
  , observeCellGraphBytes
  , GraphObservation
  , observeGraph
  , observeGraphWithUpdateCollection
  , observedDataBytes
  , observedIndirectionBytes
  , observedTotalBytes
  , observedNodeCount
  ) where

import Control.Monad (unless)
import Data.IntMap.Strict qualified as IntMap
import GHC.Exts.Heap qualified as Heap
import GHC.Exts.Heap.Closures (closureSize)
import System.Mem (performGC)
import System.Mem.StableName (eqStableName, hashStableName, makeStableName)

observeGraphBytes :: value -> IO (Integer, Int)
observeGraphBytes value = byteAndNodeCounts <$> observeGraph value

observeCellGraphBytes :: value -> IO (Integer, Int)
observeCellGraphBytes value = byteAndNodeCounts <$> observeWith CounterCell KeepUpdates value

data GraphObservation = GraphObservation !Integer !Integer !Int

observeGraph :: value -> IO GraphObservation
observeGraph = observeWith Immutable KeepUpdates

observedDataBytes, observedIndirectionBytes, observedTotalBytes :: GraphObservation -> Integer
observedDataBytes (GraphObservation bytes _ _) = bytes
observedIndirectionBytes (GraphObservation _ bytes _) = bytes
observedTotalBytes observation = observedDataBytes observation + observedIndirectionBytes observation

observedNodeCount :: GraphObservation -> Int
observedNodeCount (GraphObservation _ _ nodes) = nodes

byteAndNodeCounts :: GraphObservation -> (Integer, Int)
byteAndNodeCounts observation = (observedTotalBytes observation, observedNodeCount observation)

observeGraphWithUpdateCollection :: value -> IO GraphObservation
observeGraphWithUpdateCollection = observeWith Immutable CollectUpdates

data GraphShape = Immutable | CounterCell
data UpdateObservation = KeepUpdates | CollectUpdates

observeWith :: GraphShape -> UpdateObservation -> value -> IO GraphObservation
observeWith shape collection root = go IntMap.empty IntMap.empty [Heap.asBox root] 0 0 0
 where
  go _ _ [] !dataBytes !indirectionBytes !nodes = pure (GraphObservation dataBytes indirectionBytes nodes)
  go seen indirections (box@(Heap.Box value) : remaining) !dataBytes !indirectionBytes !nodes = do
    closure <- Heap.getBoxedClosureData box
    name <- makeStableName value
    let key = hashStableName name
        bytes = toInteger (closureSize box) * 8
        checkNodes = unless (nodes < 100000) (fail "unexpected test graph above 100000 closures")
        followIndirection child = do
          duplicate <- anyBoxEqual box (IntMap.findWithDefault [] key indirections)
          if duplicate
            then go seen indirections remaining dataBytes indirectionBytes nodes
            else do
              case collection of
                KeepUpdates -> pure ()
                CollectUpdates -> performGC
              confirmDataTarget 100000 child
              checkNodes
              go
                seen
                (IntMap.insertWith (<>) key [box] indirections)
                (child : remaining)
                dataBytes
                (indirectionBytes + bytes)
                (nodes + 1)
    case closure of
      Heap.IndClosure {Heap.indirectee = child} -> followIndirection child
      -- GHC9.12.4 Updates.h: completed blackholes point to their result.
      -- Evaluating blackholes instead lead to TSO/BLOCKING_QUEUE closures,
      -- which the ordinary traversal below still rejects without entering them.
      Heap.BlackholeClosure {Heap.indirectee = child} -> followIndirection child
      _ -> do
        let bucket = IntMap.findWithDefault [] key seen
        if any (eqStableName name) bucket
          then go seen indirections remaining dataBytes indirectionBytes nodes
          else do
            checkNodes
            case closure of
              Heap.ConstrClosure {} -> pure ()
              Heap.ArrWordsClosure {} -> pure ()
              Heap.MutVarClosure {} -> case shape of
                Immutable -> fail "immutable test value retained a mutable cell"
                CounterCell -> pure ()
              other -> fail ("quiescent test value retained an unexpected closure: " <> take 800 (show other))
            let seen' = IntMap.insert key (name : bucket) seen
            go
              seen'
              indirections
              (Heap.allClosures closure <> remaining)
              (dataBytes + bytes)
              indirectionBytes
              (nodes + 1)

  -- Collection may make formerly different Boxes equal (ghc-heap9.12.4).
  -- Resolve heads until data or the fixed chain limit, without using changing
  -- pointer equality to infer a cycle. Update-only cycles still hit the limit;
  -- data cycles stay legal and no target is entered or forced.
  confirmDataTarget remaining target
    | remaining <= (0 :: Int) = fail "unexpected update chain above 100000 closures"
    | otherwise = do
        closure <- Heap.getBoxedClosureData target
        case closure of
          Heap.ConstrClosure {} -> pure ()
          Heap.ArrWordsClosure {} -> pure ()
          Heap.MutVarClosure {} -> case shape of
            Immutable -> fail "immutable test value retained a mutable cell"
            CounterCell -> pure ()
          Heap.IndClosure {Heap.indirectee = child} ->
            confirmDataTarget (remaining - 1) child
          Heap.BlackholeClosure {Heap.indirectee = child} ->
            confirmDataTarget (remaining - 1) child
          other -> fail ("quiescent test value retained an unexpected closure: " <> take 800 (show other))

  anyBoxEqual _ [] = pure False
  anyBoxEqual box (candidate : rest) = do
    equal <- Heap.areBoxesEqual box candidate
    if equal then pure True else anyBoxEqual box rest
