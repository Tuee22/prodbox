{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module ProcessEnvironmentStorage (processEnvironmentStorageSuite) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import GHC.Exts.Heap qualified as Heap
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.Subprocess.ProcessEnvironment
import System.Mem (performGC)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

processEnvironmentStorageSuite :: SuiteBuilder ()
processEnvironmentStorageSuite = describe "captured environment storage" $ do
  it "funds the explicit empty environment graph" $ checkGraph emptyProcessEnvironment

  it "funds separate encoded key/value allocations" $
    forM_ [[], [("A", "")], [("A", "B"), ("C", "D")], [("λKEY", "😀value")]] $ \pairs -> do
      environment <- right =<< overlayProcessEnvironment pairs emptyProcessEnvironment
      checkGraph environment

  it "funds all list, pair, scalar and payload storage for many entries" $ do
    environment <-
      right
        =<< overlayProcessEnvironment
          [("NF_" <> show n, replicate 63 'x') | n <- [1 :: Int .. 256]]
          emptyProcessEnvironment
    processEnvironmentEntryCount (processEnvironmentUsage environment) @?= 256
    checkGraph environment

  it "releases rejected and replaced large backing allocations" $ do
    original <-
      right
        =<< overlayProcessEnvironment
          [("REJECTED", replicate 1048576 'x'), ("SELECTED", "small")]
          emptyProcessEnvironment
    let filtered = filterProcessEnvironment (== "SELECTED") original
    environment <- right =<< overlayProcessEnvironment [("SELECTED", "replacement")] filtered
    checkGraph environment
    (observed, _) <- observeGraphBytes environment
    assertBool "filtered environment retained the rejected allocation" (observed < 1048576)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

checkGraph :: ProcessEnvironment -> IO ()
checkGraph environment = do
  declared <- evaluate (processEnvironmentNormalFormBytes environment)
  performGC
  (observed, nodes) <- observeGraphBytes environment
  assertBool
    ( "environment graph="
        <> show observed
        <> " bytes in "
        <> show nodes
        <> " closures; declared="
        <> show declared
    )
    (observed <= toInteger declared)
  outer <- Heap.getBoxedClosureData (Heap.asBox environment)
  case outer of
    Heap.ConstrClosure _ pointers words_ _ moduleName constructor ->
      (moduleName, constructor, length pointers, length words_)
        @?= ("Prodbox.Subprocess.ProcessEnvironment", "ProcessEnvironment", 2, 0)
    other -> fail ("unexpected environment root: " <> take 300 (show other))
