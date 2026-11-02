{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, replicateM_, unless)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.Config (ResourceVector (..))
import Prodbox.Capacity.NativeHostProbe
import Prodbox.Capacity.ObservedHost
import System.Directory
import System.Environment
import System.FilePath ((</>))
import System.Posix.Env qualified as PosixEnv
import System.Posix.Files (createNamedPipe, createSymbolicLink, setFileMode)
import Text.Read (readMaybe)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

main :: IO ()
main = do
  args <- getArgs
  (directory, expected, ephemeralId, durableId) <- case args of
    [root, cpu, memory, ephemeral, durable, firstDevice, secondDevice] -> do
      let natural text = maybe (fail "expected observation integer") pure (readMaybe text)
      vector <-
        ResourceVector <$> natural cpu <*> natural memory <*> natural ephemeral <*> natural durable
      pure (root, vector, Text.pack firstDevice, Text.pack secondDevice)
    _ -> fail "native host observation fixture arguments"
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  createDirectoryIfMissing True directory
  setFileMode directory 0o700
  let tools = directory </> "tools"
      marker = directory </> "unexpected-child"
      unicode = directory </> "retained é-卷"
      link = directory </> "root-link"
      ordinary = directory </> "root-file"
      fifo = directory </> "root-fifo"
  createDirectory tools
  forM_ ["nproc", "df"] $ \name -> do
    let tool = tools </> name
    writeFile tool ("#!/bin/sh\nprintf unexpected > '" ++ marker ++ "'\nexit 99\n")
    setFileMode tool 0o700
  setEnv "PATH" tools
  setEnv "OMP_NUM_THREADS" "1"
  setEnv "OMP_THREAD_LIMIT" "1"
  now <- getMonotonicTimeNSec
  let ending = now + 20000000000
  observed <- right =<< observeNativeHostCapacityBefore ending directory
  unless
    (observedHostVector observed == expected)
    (fail "native geometry disagrees with independent kernel observation")
  unless
    ( storageDeviceIdText (observedEphemeralDevice observed) == ephemeralId
        && storageDeviceIdText (observedDurableDevice observed) == durableId
        && observedStorageDevicesCoincide observed == (ephemeralId == durableId)
    )
    (fail "descriptor-backed device identity mismatch")
  putStrLn "PASS independent host geometry under constrained CPU/memory and hostile PATH/OMP"
  createDirectory unicode
  unicodeObserved <- right =<< observeNativeHostCapacityBefore ending unicode
  unless (unicodeObserved == observed) (fail "Unicode root changed observed geometry")
  putStrLn "PASS Unicode root"
  forM_ ["", "milli_cpu=999999;memory_mib=999999"] $ \override -> do
    PosixEnv.setEnv "PRODBOX_TEST_HOST_CAPACITY" override True
    installed <- lookupEnv "PRODBOX_TEST_HOST_CAPACITY"
    unless (installed == Just override) (fail "fixture did not install its override")
    refused <- observeNativeHostCapacityBefore ending directory
    unless (refused == Left NativeHostProbeOverrideRefused) (fail "test override was accepted")
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  putStrLn "PASS both present override refusals"
  forM_ [0, now - 1] $ \expired -> do
    refused <- observeNativeHostCapacityBefore expired directory
    unless (refused == Left NativeHostProbeExpired) (fail "original expired bound was renewed")
  putStrLn "PASS original expired bounds"
  forM_
    ["relative", directory ++ "/..", directory ++ "/.", directory ++ "\NULsuffix", replicate 4097 'x']
    $ \path -> do
      refused <- observeNativeHostCapacityBefore ending path
      unless (refused == Left NativeHostProbeRootInvalid) (fail "unsafe root was accepted")
  createSymbolicLink directory link
  writeFile ordinary "synthetic-file"
  createNamedPipe fifo 0o600
  forM_ [link, ordinary, fifo, directory </> "missing-root"] $ \path -> do
    refused <- observeNativeHostCapacityBefore ending path
    case refused of
      Left (NativeHostProbeIoRefused ProbeRetained _ _) -> pure ()
      _ -> fail "unsafe or unobservable directory became observed capacity"
  putStrLn "PASS root spelling, symlink, file, FIFO and missing-root refusals"
  forM_
    [ ("MemTotal: 1048576 kB\n", 1024)
    , ("Other: 1 kB\nMemTotal:\t 0001048576 kB\n", 1024)
    , ("MemTotal: 18446744073709551615 kB\n", 18014398509481983)
    ]
    $ \(bytes, expectedMib) ->
      unless (parseNativeHostMemoryMib bytes == Right expectedMib) (fail "valid memory metadata changed")
  forM_
    [ ""
    , "MemFree: 100 kB\n"
    , "MemTotal: 1024 kB\nMemTotal: 1024 kB\n"
    , "MemTotal: 0 kB\n"
    , "MemTotal: 1023 kB\n"
    , "MemTotal: -1024 kB\n"
    , "MemTotal: +1024 kB\n"
    , "MemTotal: 1e6 kB\n"
    , "MemTotal: 1048576 MB\n"
    , "MemTotal: 18446744073709551616 kB\n"
    , "MemTotal: 000000000000000001024 kB\n"
    , "MemTotal: 1048576 kB\n" <> BS.replicate 65536 120
    , BS.pack [77, 101, 109, 84, 111, 116, 97, 108, 58, 32, 217, 161, 32, 107, 66, 10]
    ]
    $ \bytes ->
      unless
        (parseNativeHostMemoryMib bytes == Left (NativeHostProbeMetadataInvalid ProbeMemory))
        (fail "invalid memory metadata accepted")
  putStrLn "PASS 16 memory metadata boundaries"
  before <- length <$> listDirectory "/proc/self/fd"
  replicateM_ 128 $ do
    current <- right =<< observeNativeHostCapacityBefore ending directory
    unless (current == observed) (fail "stable geometry drifted")
  after <- length <$> listDirectory "/proc/self/fd"
  unless (after == before) (fail "native observations leaked descriptors")
  exists <- doesFileExist marker
  whenExists exists
  putStrLn "PASS 128 repeated observations release every descriptor; tool traps untouched"
 where
  whenExists True = fail "observation spawned a tool"
  whenExists False = pure ()
