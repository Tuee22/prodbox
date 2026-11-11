{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CanonicalDhallPathMeasurement (canonicalDhallPathMeasurementSuite) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import GHC.Generics (Generic)
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CheckedCanonicalDhallData
import System.Mem (performGC)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

data Paths = Paths {chosen :: Text, other :: Text, flag :: Bool} deriving (Generic)
instance Dhall.ToDhall Paths

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

shapes :: IO (CanonicalDhallValueShape, CanonicalDhallValueShape)
shapes = do
  ordinary <- right (compileCanonicalDhallValueShape (Dhall.declared (Dhall.inject @Paths)))
  marked <- right (markCanonicalDhallPathText ["chosen"] ordinary)
  pure (ordinary, marked)

encoded :: Text -> Bytes.ByteString
encoded path =
  Lazy.toStrict
    ( Binary.encodeExpression
        (Core.normalize (Dhall.embed Dhall.inject (Paths path (Text.replicate 65536 "unselected") True)))
    )

canonicalDhallPathMeasurementSuite :: SuiteBuilder ()
canonicalDhallPathMeasurementSuite = describe "closed path measurement" $ do
  it "counts ordinary components and ignores the unselected field" $ do
    (_, marked) <- shapes
    forM_
      [ ("", 0)
      , (".", 0)
      , ("..", 0)
      , ("...", 3)
      , ("x", 1)
      , ("abc///d", 3)
      , ("a/./b", 1)
      , ("abcd/../x", 4)
      , ("λλ/😀😀😀", 3)
      , (Text.replicate 131072 "x", 131072)
      , (Text.replicate 131072 "/", 0)
      ]
      $ \(path, expected) -> do
        usage <- right (measureCanonicalDhallValueShape marked (encoded path))
        canonicalDhallPathComponentCharacters usage @?= expected
  it "a missing or non-Text trusted coordinate refuses" $ do
    (ordinary, _) <- shapes
    assertBool "accepted missing coordinate" (isLeft (markCanonicalDhallPathText ["missing"] ordinary))
    assertBool "accepted non-Text coordinate" (isLeft (markCanonicalDhallPathText ["flag"] ordinary))
    assertBool "accepted a record as a text scalar" (isLeft (markCanonicalDhallPathText [] ordinary))
  it "annotation preserves checked decoder and refusal domains" $ do
    (ordinary, marked) <- shapes
    let bytes = encoded "a/./long-component"
    forM_
      [bytes, Bytes.empty, bytes <> "\NUL", Bytes.take (Bytes.length bytes - 1) bytes, "invalid CBOR"]
      $ \input -> do
        let before = inspectCanonicalDhallData ordinary input >>= decodeCheckedCanonicalDhallData
            after = inspectCanonicalDhallData marked input >>= decodeCheckedCanonicalDhallData
        isLeft before @?= isLeft after
        case (before, after) of
          (Right old, Right new) -> Binary.encodeExpression old @?= Binary.encodeExpression new
          _ -> pure ()
  it "usage retains only its bounded numeric graph" $ do
    (_, marked) <- shapes
    usage <- right (measureCanonicalDhallValueShape marked (encoded (Text.replicate 131072 "x")))
    declared <- evaluate (canonicalDhallUsageNormalFormBytes usage)
    performGC
    (observed, nodes) <- observeGraphBytes usage
    putStrLn
      ("usage_graph_bytes=" <> show observed <> " nodes=" <> show nodes <> " declared=" <> show declared)
    assertBool "path contents escaped into usage" (observed <= toInteger declared)
