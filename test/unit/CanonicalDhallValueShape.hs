{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module CanonicalDhallValueShape (canonicalDhallValueShapeSuite) where

import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Void (Void)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Marshal.Encode (declared)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Config.CanonicalDhallValueShape
import Test.Tasty.HUnit (assertBool, assertFailure, (@?=))
import TestSupport (SuiteBuilder, describe, it)

data Detail = Detail
  { description :: Text
  , values :: [Maybe Natural]
  }
  deriving (Generic)
instance Dhall.ToDhall Detail

data Choice = EmptyChoice | TextChoice Text | DetailChoice Detail
  deriving (Generic)
instance Dhall.ToDhall Choice

data Complete = Complete
  { enabled :: Bool
  , selected :: Choice
  , nested :: Maybe [Maybe Natural]
  }
  deriving (Generic)
instance Dhall.ToDhall Complete

right :: (Show err) => Either err value -> IO value
right = either (assertFailure . show) pure

canonical :: forall value. (Dhall.ToDhall value) => value -> Bytes.ByteString
canonical =
  Lazy.toStrict
    . Binary.encodeExpression
    . Core.normalize
    . Core.denote
    . Dhall.embed (Dhall.inject @value)

shape
  :: forall value. (Dhall.ToDhall value) => Either CanonicalDhallValueShapeError CanonicalDhallValueShape
shape = compileCanonicalDhallValueShape (declared (Dhall.inject @value))

cases :: forall value. (Dhall.ToDhall value) => String -> [value] -> SuiteBuilder ()
cases name values =
  describe name $ forM_ (zip [1 :: Int ..] values) $ \(ordinal, value) ->
    it (show ordinal) $ do
      expected <- right (shape @value)
      checkCanonicalDhallValueShape expected (canonical value) @?= Right ()

reject :: forall value. (Dhall.ToDhall value) => Bytes.ByteString -> IO ()
reject bytes = do
  expected <- right (shape @value)
  assertBool
    "foreign or malformed value shape accepted"
    (isLeft (checkCanonicalDhallValueShape expected bytes))

canonicalDhallValueShapeSuite :: SuiteBuilder ()
canonicalDhallValueShapeSuite =
  describe "canonical producer data-shape compatibility" $
    sequence_
      [ cases @Bool "booleans" [False, True]
      , cases @Natural "arbitrary-width naturals" [0, 1, 2 ^ (64 :: Int), 2 ^ (512 :: Int)]
      , cases @Integer
          "arbitrary-width signed integers"
          [0, 1, -1, 2 ^ (64 :: Int), negate (2 ^ (512 :: Int))]
      , cases @Double
          "all producer float representations"
          [0, -0, 1.5, 1 / 3, 1e100, 1 / 0, -(1 / 0), 0 / 0]
      , cases @Text
          "text including Unicode and control characters"
          ["", "ascii", "λ", "😀", "a\NULb", "line\n"]
      , cases @[Natural] "empty and nonempty lists" [[], [0], [1, 2 ^ (128 :: Int)]]
      , cases @(Maybe Natural) "optional scalar" [Nothing, Just 0, Just (2 ^ (128 :: Int))]
      , cases @(Maybe [Maybe Natural])
          "nested empty and optional types"
          [Nothing, Just [], Just [Nothing], Just [Just 0, Nothing, Just (2 ^ (128 :: Int))]]
      , cases @Choice
          "all union constructor forms"
          [EmptyChoice, TextChoice "", TextChoice "payload", DetailChoice (Detail "nested" [Nothing, Just 7])]
      , cases @Complete
          "records with nested alternatives"
          [ Complete False EmptyChoice Nothing
          , Complete True (TextChoice "payload") (Just [])
          , Complete True (DetailChoice (Detail "λ" [Just 5, Nothing])) (Just [Just 7, Nothing])
          ]
      , it "an empty list cannot substitute its element type" $
          reject @[Natural] (canonical ([] :: [Bool]))
      , it "None cannot substitute its element type" $
          reject @(Maybe Natural) (canonical (Nothing :: Maybe Bool))
      , it "a scalar cannot substitute another data shape" $ reject @Natural (canonical True)
      , it "trailing bytes remain invalid" $
          reject @Text (canonical ("text" :: Text) <> Bytes.singleton 0)
      , it "malformed CBOR remains invalid" $ reject @Complete (Bytes.pack [0x82, 8, 0xbf])
      , it "general expressions are not producer data" $
          reject @Text
            ( Lazy.toStrict
                ( Binary.encodeExpression
                    ( Core.Let (Core.makeBinding "unused" (Core.NaturalLit 0)) (Core.TextLit (Core.Chunks [] "text"))
                        :: Core.Expr Void Void
                    )
                )
            )
      ]
