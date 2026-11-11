{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- Actual RTS update states on the pinned unprofiled ABI. The controlled
-- unsafePerformIO fixture exists only to hold an evaluation at its MVar.
module HeapGraphUpdates (heapGraphUpdatesSuite) where

import Control.Concurrent (ThreadId, threadDelay)
import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, evaluate, finally, try)
import Control.Monad (forM_, void)
import Data.IORef (newIORef, readIORef)
import Data.List (isInfixOf)
import GHC.Conc.Sync (ThreadStatus (..), threadStatus)
import GHC.Exts.Heap qualified as Heap
import PinnedHeapGraph
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty.HUnit (assertBool, assertFailure, (@?=))
import TestSupport (SuiteBuilder, describe, it)

heapGraphUpdatesSuite :: SuiteBuilder ()
heapGraphUpdatesSuite = describe "evaluated update headers on the pinned ABI" $ do
  it "counts an evaluated blackhole header and its data referent separately" $ do
    seed <- newIORef (97 :: Int) >>= readIORef
    boxed <- evaluate (Heap.asBox (strictLeaf seed))
    holder <- newIORef boxed
    forceBox boxed
    root <- readIORef holder
    graph <- observeGraph root
    observedDataBytes graph @?= 48
    observedIndirectionBytes graph @?= 16
    observedTotalBytes graph @?= 64
  it "shares one data referent and one header across repeated aliases" $ do
    seed <- newIORef (101 :: Int) >>= readIORef
    boxed <- evaluate (Heap.asBox (strictLeaf seed))
    holder <- newIORef boxed
    forceBox boxed
    root <- readIORef holder
    one <- observeGraph root
    let pair = (root, root)
    both <- observeGraph pair
    observedDataBytes both @?= observedDataBytes one + 24
    observedIndirectionBytes both @?= observedIndirectionBytes one
  it "follows a completed CAF update chain and retains its headers" $ do
    boxed <- evaluate (Heap.asBox cafLeaf)
    holder <- newIORef boxed
    forceBox boxed
    root <- readIORef holder
    graph <- observeGraph root
    observedDataBytes graph @?= 48
    assertBool "CAF did not retain its two update headers" (observedIndirectionBytes graph >= 32)
    observedTotalBytes graph @?= observedDataBytes graph + observedIndirectionBytes graph
    print ("caf_update_graph" :: String, observedDataBytes graph, observedIndirectionBytes graph)
  it "keeps a completed update target after collection aliases its header" $ do
    seed <- newIORef (109 :: Int) >>= readIORef
    boxed <- evaluate (Heap.asBox (strictLeaf seed))
    holder <- newIORef boxed
    forceBox boxed
    root <- readIORef holder
    graph <- observeGraphWithUpdateCollection root
    observedDataBytes graph @?= 48
    assertBool "the controlled fixture did not observe an update" (observedIndirectionBytes graph >= 16)
  it "accepts quiescent constructor cycles across update collection" $ do
    seed <- newIORef (113 :: Int) >>= readIORef
    node <- evaluate (let cyclic = CyclicData seed cyclic in cyclic)
    graph <- observeGraphWithUpdateCollection node
    assertBool
      "the finite cyclic data was not observed"
      (observedDataBytes graph > 0 && observedDataBytes graph <= 40)
  it "refuses an active owner without entering it and joins the released worker" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    boxed <- evaluate (Heap.asBox (pendingLeaf entered release))
    withAsync (forceBox boxed) $ \worker ->
      ( do
          takeMVar entered
          awaitBlocked 1000 (asyncThreadId worker)
          forM_ [observeGraph, observeGraphWithUpdateCollection] $ \observe ->
            assertActiveOwnerRefusal observe boxed
          putMVar release ()
          wait worker
      )
        `finally` void (tryPutMVar release ())

{-# NOINLINE strictLeaf #-}
strictLeaf :: Int -> Maybe Int
strictLeaf n = let result = n + 1 in result `seq` Just result

{-# NOINLINE cafLeaf #-}
cafLeaf :: Maybe Int
cafLeaf = strictLeaf 107

forceBox :: Heap.Box -> IO ()
forceBox (Heap.Box value) = void (evaluate value)

{-# NOINLINE pendingLeaf #-}
pendingLeaf :: MVar () -> MVar () -> Maybe Int
pendingLeaf entered release = unsafePerformIO $ do
  putMVar entered ()
  takeMVar release
  pure (Just 103)

awaitBlocked :: Int -> ThreadId -> IO ()
awaitBlocked remaining thread
  | remaining <= 0 = fail "the controlled worker did not reach its blocking MVar"
  | otherwise = do
      status <- threadStatus thread
      case status of
        ThreadBlocked _ -> pure ()
        ThreadDied -> fail "the controlled worker died before observation"
        ThreadFinished -> fail "the controlled worker finished before observation"
        ThreadRunning -> threadDelay 1000 >> awaitBlocked (remaining - 1) thread

data CyclicData = CyclicData !Int CyclicData

assertActiveOwnerRefusal :: (Heap.Box -> IO GraphObservation) -> Heap.Box -> IO ()
assertActiveOwnerRefusal observe boxed = do
  refused <- try (observe boxed)
  case refused of
    Left (cause :: SomeException) ->
      assertBool
        ("unrelated active-computation refusal: " <> show cause)
        ("tipe = TSO" `isInfixOf` show cause || "tipe = BLOCKING_QUEUE" `isInfixOf` show cause)
    Right _ -> assertFailure "an evaluating thunk became accepted data"
