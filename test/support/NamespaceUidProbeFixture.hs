{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module NamespaceUidProbeFixture (main, Shape (..), maximumBytes, input) where

import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Bytes8
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter (parseKubernetesNamespaceUid)
import System.Environment (getArgs)

data Shape = DenseNumbers | SingletonArrays | EmptyObjects | DeepArray

main :: IO ()
main = do
  arguments <- getArgs
  shape <- case arguments of
    ["dense-numbers"] -> pure DenseNumbers
    ["singleton-arrays"] -> pure SingletonArrays
    ["empty-objects"] -> pure EmptyObjects
    ["deep-array"] -> pure DeepArray
    _ -> fail "expected one registered decoder probe shape"
  let body = input shape
  unless (Bytes.length body == maximumBytes) (fail "fixture lost full SDK output domain")
  result <- evaluate (parseKubernetesNamespaceUid (Text.pack (Bytes8.unpack body)))
  case result of
    Right uid
      | uid == "fixture-uid" ->
          putStrLn ("PARSER_PROBE_PASSED " <> Text.unpack uid <> " input_bytes=" <> show maximumBytes)
    other -> fail ("namespace parser returned: " <> show other)

maximumBytes :: Int
maximumBytes = 2 * 1048576

input :: Shape -> Bytes.ByteString
input shape = case shape of
  DenseNumbers -> repeated "1,"
  SingletonArrays -> repeated "[1],"
  EmptyObjects -> repeated "{},"
  DeepArray ->
    let depth = (maximumBytes - Bytes.length prefix - Bytes.length suffix - 1) `div` 2
        content = Bytes.replicate depth 91 <> "0" <> Bytes.replicate depth 93
     in padded content
 where
  prefix = "{\"padding\":["
  suffix = "],\"metadata\":{\"uid\":\"fixture-uid\"}}"
  padded content =
    let used = Bytes.length prefix + Bytes.length content + Bytes.length suffix
     in Bytes.concat [prefix, content, suffix, Bytes.replicate (maximumBytes - used) 32]
  repeated patternBytes =
    let width = Bytes.length patternBytes
        count = (maximumBytes - Bytes.length prefix - Bytes.length suffix + 1) `div` width
        countBytes = count * width - 1
        (content, _) =
          Bytes.unfoldrN
            countBytes
            (\ordinal -> Just (Bytes.index patternBytes (ordinal `mod` width), ordinal + 1))
            (0 :: Int)
     in padded content
