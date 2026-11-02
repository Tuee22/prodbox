{-# LANGUAGE OverloadedStrings #-}

-- | Exercise the actual owner through repeated short-child teardown windows.
-- Each call retains the original 500 ms diagnostic envelope; no retry of a
-- failed command is admitted. This does not qualify the aggregate deployment.
module Main (main) where

import Control.Monad (forM_, unless)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitSuccess))

main :: IO ()
main = do
  arguments <- getArgs
  iterations <- case arguments of
    [] -> pure 64
    ["stress"] -> pure 2048
    _ -> fail "expected no arguments or the fixed stress profile"
  resources <-
    either (fail . show) pure $
      mkOwnedSubprocessResourceBounds 67108864 16 1000000 16777216 8 1000000 30000 30000
  limits <-
    either (fail . show) pure $
      mkOwnedSubprocessLimits resources 500000 50000 100000 50000 128 128
  forM_ [1 .. (iterations :: Int)] $ \iteration -> do
    started <- getMonotonicTimeNSec
    result <- captureOwnedSubprocess limits (Subprocess "/bin/true" [] Nothing Nothing)
    finished <- getMonotonicTimeNSec
    print (iteration, result, (finished - started) `div` 1000)
    unless
      (result == Right (ProcessOutput ExitSuccess "" "") && finished - started < 500000000)
      (fail "short child did not retire successfully inside its original bound")
