{-# LANGUAGE ImportQualifiedPost #-}

module PinnedByteStringData (pinnedByteStringDataSuite) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Internal qualified as BytesInternal
import Data.Word (Word8)
import Foreign.ForeignPtr (newForeignPtr_)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Storable (poke)
import PinnedHeapGraph qualified as Graph
import Prodbox.Capacity.PinnedByteStringData
import Test.Tasty.HUnit (assertBool, (@?=))
import TestSupport (SuiteBuilder, describe, it)

pinnedByteStringDataSuite :: SuiteBuilder ()
pinnedByteStringDataSuite = describe "pinned ByteString backing observation" $ do
  it "observes owned compact storage against the independent heap graph" $ do
    forM_ [(1, 72), (37, 104), (64, 128), (65, 136)] $ \(size, expected) -> do
      let bytes = Bytes.copy (Bytes.replicate size 173)
      _ <- evaluate (Bytes.length bytes)
      backing <- accepted =<< observePinnedByteStringData bytes
      pinnedByteStringDataBytes backing @?= expected
      graph <- Graph.observeGraph bytes
      assertBool
        "managed storage projection undercounts actual data"
        (Graph.observedDataBytes graph <= toInteger expected)
  it "observes the full allocation retained by offset views" $ do
    let storage = Bytes.copy (Bytes.replicate 4096 181)
    forM_ [(1, 7), (37, 17), (64, 64)] $ \(size, offset) -> do
      let bytes = Bytes.take size (Bytes.drop offset storage)
      _ <- evaluate (Bytes.length bytes)
      backing <- accepted =<< observePinnedByteStringData bytes
      pinnedByteStringDataBytes backing @?= 4160
      graph <- Graph.observeGraph bytes
      Graph.observedDataBytes graph @?= 4160
      bytes @?= Bytes.replicate size 181
  it "conservatively accounts for aliased views without claiming duplicate allocation" $ do
    let storage = Bytes.copy (Bytes.replicate 4096 193)
        first = Bytes.take 16 storage
        second = Bytes.take 24 (Bytes.drop 41 storage)
    _ <- evaluate (Bytes.length first + Bytes.length second)
    a <- accepted =<< observePinnedByteStringData first
    b <- accepted =<< observePinnedByteStringData second
    pinnedByteStringDataBytes a @?= 4160
    pinnedByteStringDataBytes b @?= 4160
    graph <- Graph.observeGraph (first, second)
    assertBool
      "separate observations undercount the shared graph"
      ( Graph.observedDataBytes graph
          <= toInteger (24 + pinnedByteStringDataBytes a + pinnedByteStringDataBytes b)
      )
    assertBool
      "the graph did not retain sharing"
      ( Graph.observedDataBytes graph
          < toInteger (24 + pinnedByteStringDataBytes a + pinnedByteStringDataBytes b)
      )
  it "refuses oversized backing and corroborates an equal compact copy" $ do
    let storage = Bytes.copy (Bytes.replicate 4096 211)
    forM_ [(1, 7, 72), (37, 17, 104), (64, 64, 128)] $ \(size, offset, expected) -> do
      let source = Bytes.take size (Bytes.drop offset storage)
      observeCompactPinnedByteStringData source
        >>= (@?= Left (PinnedByteStringCompactBoundExceeded 4160 expected))
      let compact = Bytes.copy source
      backing <- accepted =<< observeCompactPinnedByteStringData compact
      pinnedByteStringDataBytes backing @?= expected
      compact @?= source
      graph <- Graph.observeGraph compact
      assertBool
        "corroborated copy exceeds its data term"
        (Graph.observedDataBytes graph <= toInteger expected)
  it "refuses valid borrowed storage without reading its contents" $
    allocaBytes 1 $ \pointer -> do
      poke pointer (0 :: Word8)
      borrowed <- newForeignPtr_ pointer
      let bytes = BytesInternal.fromForeignPtr borrowed 0 1
      observePinnedByteStringData bytes >>= (@?= Left PinnedByteStringBackingUnsupported)
      observeCompactPinnedByteStringData bytes >>= (@?= Left PinnedByteStringBackingUnsupported)
  it "refuses invalid managed lengths before any payload read" $ do
    let storage = Bytes.copy (Bytes.replicate 8 227)
    _ <- evaluate (Bytes.length storage)
    let (pointer, _, _) = BytesInternal.toForeignPtr storage
    forM_ [-1, 4097] $ \size -> do
      -- Only the observer sees these fixed invalid headers. Neither case is
      -- copied, traversed or passed to a payload reader.
      let bytes = BytesInternal.fromForeignPtr pointer 0 size
      observePinnedByteStringData bytes >>= (@?= Left PinnedByteStringLengthInvalid)

accepted :: Either PinnedByteStringDataError value -> IO value
accepted result = case result of
  Left cause -> fail (show cause)
  Right value -> pure value
