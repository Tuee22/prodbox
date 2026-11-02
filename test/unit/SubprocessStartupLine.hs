{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module SubprocessStartupLine (subprocessStartupLineSuite) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as Memory
import Prodbox.ControlPlane.HomeEndpoint
import Prodbox.Subprocess
import Prodbox.Subprocess.StartupLine
import TestSupport

subprocessStartupLineSuite :: SuiteBuilder ()
subprocessStartupLineSuite = describe "owned transport startup acknowledgement" $ do
  -- FORWARD-STARTUP-HANDSHAKE-2026-08-28 records this actual kubectl mapping.
  -- The owned path must establish the same first-line fact before HTTP.
  let linesForPort = homeControlPlaneForwardStartupLines HomeLifecycleAuthority 45124
      expected = must (mkStartupLineExpectation (map Bytes.pack linesForPort))
      feed = BS.foldl' feedStartupLineByte
      status bytes = startupLineStatus (feed (beginStartupLine expected) bytes)

  it "accepts both exact loopback forms across every fragmentation boundary" $
    forM_ linesForPort $ \line -> do
      let wire = Bytes.pack (line <> "\n")
      forM_ [0 .. BS.length wire] $ \position -> do
        let chunks = [BS.take position wire, BS.drop position wire]
        startupLineStatus (foldl' feed (beginStartupLine expected) chunks)
          `shouldBe` StartupLineAccepted

  it "requires the terminating newline rather than promoting a visible prefix" $
    forM_ linesForPort $ \line -> do
      let wire = Bytes.pack line
      forM_ [0 .. BS.length wire] $ \position ->
        status (BS.take position wire) `shouldBe` StartupLinePending

  it "keeps complete acknowledgement independent of later connection messages" $
    forM_ linesForPort $ \line ->
      status (Bytes.pack (line <> "\nHandling connection for 8600\n"))
        `shouldBe` StartupLineAccepted

  it "refuses foreign mappings, extra bytes and a later corrective line" $
    forM_
      [ "Forwarding from 0.0.0.0:45124 -> 8600\n"
      , "Forwarding from 127.0.0.1:45125 -> 8600\n"
      , "Forwarding from 127.0.0.1:45124 -> 8601\n"
      , "Forwarding from 127.0.0.1:45124 -> 8600 \n"
      , "Forwarding from 127.0.0.1:45124 -> 8600\r\n"
      , "Forwarding from 127.0.0.1:45124 -> 8600\NUL\n"
      , "\n"
      , "unexpected\nForwarding from 127.0.0.1:45124 -> 8600\n"
      ]
      (\wire -> status wire `shouldBe` StartupLineRejected)

  it "keeps empty, partial and unterminated EOF observations incomplete" $
    forM_ [BS.empty, "Forwarding from ", "Forwarding from 127.0.0.1:45124 -> 8600"] $ \wire ->
      finishStartupLine (feed (beginStartupLine expected) wire)
        `shouldBe` StartupLineIncomplete

  it "bounds both the expected first line and the consumed prefix" $ do
    let widest = BS.replicate 256 120
        full = must (mkStartupLineExpectation [widest])
    startupLineStatus (feed (beginStartupLine full) (widest <> "\n"))
      `shouldBe` StartupLineAccepted
    startupLineStatus (feed (beginStartupLine full) (widest <> "x\n"))
      `shouldBe` StartupLineRejected
    patternError [BS.replicate 257 120] `shouldBe` Just StartupLinePatternTooLong

  it "refuses absent, duplicated, excessive and non-textual expectations" $
    forM_
      [ ([], StartupLinePatternCountInvalid)
      , (["a", "b", "c"], StartupLinePatternCountInvalid)
      , (["same", "same"], StartupLinePatternDuplicate)
      , ([BS.empty], StartupLinePatternInvalid)
      , (["bad\nline"], StartupLinePatternInvalid)
      , (["bad\NULline"], StartupLinePatternInvalid)
      , ([BS.pack [255]], StartupLinePatternInvalid)
      ]
      (\(patterns, cause) -> patternError patterns `shouldBe` Just cause)

  it "refuses invalid local ports before constructing expected mappings" $ do
    homeControlPlaneForwardStartupLines HomeAuthorityBackup 0 `shouldBe` []
    homeControlPlaneForwardStartupLines HomeLifecycleAuthority 65536 `shouldBe` []

  describe "funding in the observed parent's existing stream reserve" $ do
    let streams = must (mkOperationStreamLimits 4096 4096 100000)
        oldReserve = 4 * (4096 + 4096 + 2)
        funded = oldReserve + 2 * fromInteger startupLineReserveBytes

    it "rejects startup metadata when ordinary buffers exhaust the reserve" $ do
      let runtime = runtimeWithReserve oldReserve
      validateOperationStreamLimits runtime window streams `shouldBe` Right ()
      validateOperationTransportStartupLimits runtime window streams expected
        `shouldBe` Left OwnedSubprocessInvalidLimits

    it "fits exactly at the funded boundary without enlarging the heap or outer envelope" $ do
      let runtime = runtimeWithReserve funded
      validateOperationTransportStartupLimits runtime window streams expected `shouldBe` Right ()
      Memory.positiveBytesValue (Memory.runtimeMemoryHeapCapBytes runtime) `shouldBe` mib 128
      Memory.positiveBytesValue (Memory.runtimeMemoryContainerLimitBytes runtime) `shouldBe` mib 256

    it "still applies the original stream clock constraints" $ do
      let runtime = runtimeWithReserve funded
          lateGrace = must (mkOperationStreamLimits 4096 4096 2000000)
      validateOperationTransportStartupLimits runtime window lateGrace expected
        `shouldBe` Left OwnedSubprocessInvalidLimits

patternError :: [ByteString] -> Maybe StartupLineError
patternError = either Just (const Nothing) . mkStartupLineExpectation

runtimeWithReserve :: Integer -> Memory.RuntimeMemoryPlan
runtimeWithReserve reserve =
  must $
    Memory.validateRuntimeMemoryPlan
      Memory.RuntimeMemoryInputs
        { Memory.runtimeBoundedApplicationState = positive Memory.BoundedApplicationState (mib 2)
        , Memory.runtimeBoundedPendingPersistenceState =
            positive Memory.BoundedPendingPersistenceState (mib 1)
        , Memory.runtimeInHeapTransportDecodeScratch = positive Memory.InHeapTransportDecodeScratch (mib 3)
        , Memory.runtimeOtherHeapReserve = positive Memory.OtherHeapReserve (fromIntegral reserve)
        , Memory.runtimeHeapCap = positive Memory.HeapCap (mib 128)
        , Memory.runtimeNativeNonHeapReserve = positive Memory.NativeNonHeapReserve (mib 32)
        , Memory.runtimeRawChildSchedule = Memory.BoundedChildSchedule 2 (Just 30000000) [mib 64, mib 16]
        , Memory.runtimeKernelCgroupReserve = positive Memory.KernelCgroupReserve (mib 8)
        , Memory.runtimeSafetyMargin = positive Memory.SafetyMargin (mib 8)
        , Memory.runtimeContainerMemoryLimit = positive Memory.ContainerMemoryLimit (mib 256)
        }
 where
  positive term = must . Memory.mkPositiveBytes term

window :: HostExecutionWindow
window =
  maybe (error "invalid startup fixture window") id $
    hostExecutionWindow 10000000000 7000000000 8000000000 9000000000 9500000000

mib :: Natural -> Natural
mib value = value * 1048576

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
