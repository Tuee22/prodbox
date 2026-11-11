{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module CanonicalDhallTokenMatchTests (canonicalDhallTokenMatchSuite) where

import Codec.CBOR.ByteArray.Sliced qualified as Sliced
import Codec.CBOR.Encoding qualified as Encoding
import Codec.CBOR.Write qualified as CborWrite
import Control.Monad (forM_)
import Data.Bits (xor)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Prodbox.Config.CanonicalDhallTokenMatch qualified as TokenMatch
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

canonicalDhallTokenMatchSuite :: SuiteBuilder ()
canonicalDhallTokenMatchSuite = describe "canonical SDK token byte comparison" $ do
  it "agrees with the pinned SDK writer across constructors, bounds and byte mutations" $ do
    counts <- mapM assertSdkTokenMatch sdkTokenExamples
    putStrLn
      ( "canonical_token_match_sdk_programs="
          <> show (length counts)
          <> "; comparisons="
          <> show (sum counts)
      )
  it "does not force the suffix after a first-byte mismatch" $
    TokenMatch.matchCanonicalDhallTokens
      Bytes.empty
      (Encoding.TkNull (error "mismatch forced token suffix"))
      @?= Right False
  it "returns typed refusals for unsupported constructors" $
    forM_ [Encoding.encodeBytes (Bytes.singleton 1), Encoding.encodeDouble 1, Encoding.encodeInt (-1)] $ \(Encoding.Encoding produce) ->
      TokenMatch.matchCanonicalDhallTokens (Bytes.singleton 0) (produce Encoding.TkEnd)
        @?= Left TokenMatch.CanonicalTokenUnsupported
  it "refuses invalid UTF8 array views before indexing" $ do
    let Sliced.SBA array _ size = Sliced.fromByteString "payload"
    forM_ [(-1, 1), (0, -1), (size + 1, 0), (1, size)] $ \(start, count) ->
      TokenMatch.matchCanonicalDhallTokens
        Bytes.empty
        (Encoding.TkUtf8ByteArray (Sliced.SBA array start count) Encoding.TkEnd)
        @?= Left TokenMatch.CanonicalTokenInvalidView
  it "compares the existing one-MiB Text domain and its final-byte mismatch" $ do
    let encoding@(Encoding.Encoding produce) = Encoding.encodeString (Text.replicate (1048576 - 7) "x")
        wire = CborWrite.toStrictByteString encoding
        tokens = produce Encoding.TkEnd
        changed = Bytes.init wire <> Bytes.singleton (Bytes.last wire `xor` 1)
    TokenMatch.matchCanonicalDhallTokens wire tokens @?= Right True
    TokenMatch.matchCanonicalDhallTokens changed tokens @?= Right False
  it "compares definite binary payloads without widening the Dhall interpreter" $
    forM_ [0, 1, 23, 24, 255, 256, 4096, 65536] $ \count -> do
      let payload = Bytes.pack (take count (cycle [0 .. 255]))
          parent = "prefix" <> payload <> "suffix"
          selected = Bytes.take count (Bytes.drop 6 parent)
          whole = Sliced.fromByteString parent
          sliced = case whole of Sliced.SBA array _ _ -> Sliced.SBA array 6 count
      forM_ [Encoding.encodeBytes selected, Encoding.encodeByteArray sliced] $ \encoding@(Encoding.Encoding produce) -> do
        let wire = CborWrite.toStrictByteString encoding
            tokens = produce Encoding.TkEnd
        TokenMatch.matchCanonicalBinaryTokens wire tokens @?= Right True
        TokenMatch.matchCanonicalDhallTokens wire tokens @?= Left TokenMatch.CanonicalTokenUnsupported
        forM_
          [ Bytes.take (Bytes.length wire - 1) wire
          , wire <> Bytes.singleton 0
          , Bytes.init wire <> Bytes.singleton (Bytes.last wire `xor` 1)
          ]
          $ \changed -> TokenMatch.matchCanonicalBinaryTokens changed tokens @?= Right False
  it "refuses invalid binary array views before indexing" $ do
    let Sliced.SBA array _ size = Sliced.fromByteString "payload"
    forM_ [(-1, 1), (0, -1), (size + 1, 0), (1, size)] $ \(start, count) ->
      TokenMatch.matchCanonicalBinaryTokens
        Bytes.empty
        (Encoding.TkByteArray (Sliced.SBA array start count) Encoding.TkEnd)
        @?= Left TokenMatch.CanonicalTokenInvalidView

sdkTokenExamples :: [(String, Encoding.Encoding)]
sdkTokenExamples =
  [ ("word/" <> show value, Encoding.Encoding (Encoding.TkWord (fromInteger value))) | value <- unsigned
  ]
    <> [ ("word64/" <> show value, Encoding.Encoding (Encoding.TkWord64 (fromInteger value)))
       | value <- unsigned
       ]
    <> [("int/" <> show value, Encoding.Encoding (Encoding.TkInt (fromInteger value))) | value <- signed]
    <> [ ("int64/" <> show value, Encoding.Encoding (Encoding.TkInt64 (fromInteger value))) | value <- signed
       ]
    <> [ ("integer/" <> show index, Encoding.Encoding (Encoding.TkInteger value))
       | (index, value) <- zip [0 :: Int ..] integers
       ]
    <> [ ("list/" <> show value, Encoding.Encoding (Encoding.TkListLen (fromInteger value)))
       | value <- unsigned
       ]
    <> [ ("map/" <> show value, Encoding.Encoding (Encoding.TkMapLen (fromInteger value)))
       | value <- unsigned
       ]
    <> [ ("tag/" <> show value, Encoding.Encoding (Encoding.TkTag (fromInteger value))) | value <- unsigned
       ]
    <> [ ("tag64/" <> show value, Encoding.Encoding (Encoding.TkTag64 (fromInteger value)))
       | value <- unsigned
       ]
    <> [("text/" <> show index, Encoding.encodeString value) | (index, value) <- zip [0 :: Int ..] texts]
    <> [ ("utf8/slice", Encoding.encodeUtf8ByteArray slice)
       , ("utf8/whole", Encoding.encodeUtf8ByteArray whole)
       ]
    <> [ ("null", Encoding.encodeNull)
       , ("false", Encoding.encodeBool False)
       , ("true", Encoding.encodeBool True)
       ]
    <> [
         ( "mixed map"
         , Encoding.encodeMapLen 2
             <> Encoding.encodeString "a"
             <> Encoding.encodeListLen 3
             <> Encoding.encodeWord 24
             <> Encoding.encodeInteger (2 ^ (72 :: Int) + 9)
             <> Encoding.encodeBool False
             <> Encoding.encodeString "b"
             <> Encoding.encodeString "λ🙂"
         )
       ]
 where
  unsigned :: [Integer]
  unsigned =
    [ 0
    , 1
    , 23
    , 24
    , 255
    , 256
    , 65535
    , 65536
    , 2 ^ (32 :: Int) - 1
    , 2 ^ (32 :: Int)
    , 2 ^ (63 :: Int) - 1
    , 2 ^ (63 :: Int)
    , 2 ^ (64 :: Int) - 1
    ]
  signed = filter (<= 2 ^ (63 :: Int) - 1) unsigned
  integers =
    unsigned
      <> [ 2 ^ (64 :: Int)
         , 2 ^ (64 :: Int) + 1
         , 2 ^ (65 :: Int) - 1
         , 2 ^ (65 :: Int)
         , 2 ^ (72 :: Int) - 1
         , 2 ^ (80 :: Int) + 53
         , 2 ^ (4096 :: Int)
         ]
  texts = ["", "ascii", "λ", "λ🙂\NUL/", "𝄞", Text.replicate 300 "x", Text.drop 1 "πpayload🙂suffix"]
  whole = Sliced.fromByteString "prefixpayloadsuffix"
  slice = case whole of Sliced.SBA array _ _ -> Sliced.SBA array 6 7

assertSdkTokenMatch :: (String, Encoding.Encoding) -> IO Int
assertSdkTokenMatch (label, encoding@(Encoding.Encoding produce)) = do
  let wire = CborWrite.toStrictByteString encoding
      tokens = produce Encoding.TkEnd
      sliced = Bytes.take (Bytes.length wire) (Bytes.drop 3 ("pre" <> wire <> "suffix"))
      variants =
        [wire, sliced, Bytes.take (Bytes.length wire - 1) wire, wire <> Bytes.singleton 0]
          <> [ Bytes.take index wire
                 <> Bytes.singleton (Bytes.index wire index `xor` 1)
                 <> Bytes.drop (index + 1) wire
             | index <- [0 .. Bytes.length wire - 1]
             ]
  forM_ variants $ \target -> do
    assertEqual
      (label <> "/raw")
      (Right (target == wire))
      (TokenMatch.matchCanonicalDhallTokens target tokens)
  pure (Bytes.length wire + 4)
