{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as Bytes
import Data.List (isPrefixOf)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import Prodbox.Subprocess.ProcessEnvironment
import System.Environment (getEnvironment, lookupEnv)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

check :: String -> Bool -> IO ()
check label result = unless result (fail label) >> putStrLn ("PASS " <> label)

encode :: [(String, String)] -> IO [(Bytes.ByteString, Bytes.ByteString)]
encode entries = do
  encoding <- getFileSystemEncoding
  let one value = GHC.withCStringLen encoding value Bytes.packCStringLen
  traverse (\(key, value) -> (,) <$> one key <*> one value) entries

main :: IO ()
main = do
  sentinel <- lookupEnv "PRODBOX_ENV_FIXTURE"
  unless (sentinel == Just "synthetic-no-secrets") (fail "complete synthetic environment required")
  original <- getEnvironment
  expected <- encode original
  now <- getMonotonicTimeNSec
  captured <- right =<< captureProcessEnvironmentBefore (now + 5000000000)
  check
    "complete native bytes match GHC filesystem encoding"
    (processEnvironmentNativeEntries captured == expected)
  check
    "usage includes each encoded separator and terminator"
    ( processEnvironmentUsage captured
        == ProcessEnvironmentUsage
          (fromIntegral (length expected))
          (sum [fromIntegral (Bytes.length key + Bytes.length value + 2) | (key, value) <- expected])
    )
  expired <- captureProcessEnvironmentBefore now
  check "expired capture refuses" $ case expired of
    Left ProcessEnvironmentDeadlineReached -> True
    _ -> False
  unchanged <- right =<< overlayProcessEnvironment [] captured
  check
    "empty overlay preserves entries and order"
    (processEnvironmentNativeEntries unchanged == expected)
  let overrides =
        [("HOME", "/synthetic/λ"), ("DUPLICATE", "first"), ("DUPLICATE", "second"), ("NEW_VALUE", "λ=😀\n")]
      replaced = map fst overrides
      updated = overrides <> filter (not . (`elem` replaced) . fst) original
  expectedOverlay <- encode updated
  overlaid <- right =<< overlayProcessEnvironment overrides captured
  check
    "overlay preserves other keys and duplicate ordering"
    (processEnvironmentNativeEntries overlaid == expectedOverlay)
  check
    "PATH is inherited"
    (lookup "PATH" (processEnvironmentNativeEntries overlaid) == lookup "PATH" expected)
  let filtered = filterProcessEnvironment (not . Bytes.isPrefixOf "AWS_") captured
  expectedFiltered <- encode (filter (not . isPrefixOf "AWS_" . fst) original)
  check
    "key filter preserves the remaining native values"
    (processEnvironmentNativeEntries filtered == expectedFiltered)
  forM_
    [ ("empty authored key", "", "value")
    , ("separator in authored key", "BAD=KEY", "value")
    , ("NUL in authored key", "BAD\NULKEY", "value")
    , ("NUL in authored value", "KEY", "bad\NULvalue")
    ]
    $ \(label, key, value) -> do
      result <- overlayProcessEnvironment [(key, value)] captured
      checkInvalid label result
  putStrLn "ENVIRONMENT_SEMANTICS_PASSED controls=11"

checkInvalid :: String -> Either ProcessEnvironmentError ProcessEnvironment -> IO ()
checkInvalid label result = check label $ case result of
  Left ProcessEnvironmentOverlayInvalid -> True
  _ -> False
