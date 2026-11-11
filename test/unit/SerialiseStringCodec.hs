{-# LANGUAGE ImportQualifiedPost #-}

module SerialiseStringCodec (serialiseStringCodecSuite) where

import Codec.CBOR.Term qualified as Term
import Codec.Serialise qualified as Sdk
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified
import Data.Char (chr)
import Data.Either (isLeft)
import Data.Text.Encoding qualified as Text
import Prodbox.Config.SerialiseString
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

serialiseStringCodecSuite :: SuiteBuilder ()
serialiseStringCodecSuite = describe "checked serialise String" $ do
  it "every Char code point keeps the SDK's encoded-value domain" $
    forM_ [0 .. 0x10ffff] $ \code -> do
      let original = [chr code]
          encoded = Sdk.serialise original
      decoded <- right (Sdk.deserialiseOrFail encoded)
      serialiseStringValue decoded @?= original
      payload <- stringPayload encoded
      generalisedUtf8ScalarCount payload @?= Just 1
  it "mixed strings keep exact SDK bytes, including surrogates"
    $ forM_
      [ []
      , ['a', '\0', 'b']
      , [chr 0xd7ff, chr 0xd800, chr 0xdfff, chr 0xe000]
      , replicate 131072 'x' <> [chr 0xdc80]
      ]
    $ \original -> do
      let encoded = Sdk.serialise original
      decoded <- right (Sdk.deserialiseOrFail encoded)
      serialiseStringValue decoded @?= original
      Sdk.serialise decoded @?= encoded
      payload <- stringPayload encoded
      generalisedUtf8ScalarCount payload @?= Just (fromIntegral (length original))
  it "scalar counting follows SDK characters across sliced payloads" $
    forM_ [[], "a\NULb", ['\955', '\x10000'], [chr 0xd800, chr 0xdfff, 'x']] $ \original -> do
      payload <- stringPayload (Sdk.serialise original)
      forM_ [0 .. 7] $ \padding -> do
        let backing = Bytes.replicate padding 0xff <> payload <> Bytes.replicate 8 0x80
            selected = Bytes.take (Bytes.length payload) (Bytes.drop padding backing)
        generalisedUtf8ScalarCount selected @?= Just (fromIntegral (length original))
  it "all malformed one-byte fields refuse before String decoding" $
    forM_ [0 .. 255] $ \byte -> do
      let payload = Bytes.singleton byte
          decoded = Sdk.deserialiseOrFail (Sdk.serialise payload) :: Either Sdk.DeserialiseFailure SerialiseString
      validGeneralisedUtf8 payload @?= (byte <= 0x7f)
      generalisedUtf8ScalarCount payload @?= if byte <= 0x7f then Just 1 else Nothing
      isLeft decoded @?= (byte > 0x7f)
  it "truncation, overlong forms and out-of-range values refuse"
    $ forM_
      [ [0xc2]
      , [0xe0]
      , [0xf0]
      , [0xc0, 0xaf]
      , [0xe0, 0x80, 0x80]
      , [0xf0, 0x80, 0x80, 0x80]
      , [0xf4, 0x90, 0x80, 0x80]
      , [0xf5, 0x80, 0x80, 0x80]
      , [0xed, 0xa0]
      , [0xe1, 0x80, 0x41]
      ]
    $ \bytes -> do
      let payload = Bytes.pack bytes
          decoded = Sdk.deserialiseOrFail (Sdk.serialise payload) :: Either Sdk.DeserialiseFailure SerialiseString
      validGeneralisedUtf8 payload @?= False
      generalisedUtf8ScalarCount payload @?= Nothing
      assertBool "malformed generalized UTF8 reached the SDK String decoder" (isLeft decoded)
  it "valid byte-string fields keep the SDK's canonicality behavior"
    $ forM_
      [ []
      , [0x00]
      , [0xc2, 0x80]
      , [0xe0, 0xa0, 0x80]
      , [0xed, 0xa0, 0x80]
      , [0xed, 0xbf, 0xbf]
      , [0xf0, 0x90, 0x80, 0x80]
      , [0xf4, 0x8f, 0xbf, 0xbf]
      ]
    $ \bytes -> do
      let payload = Bytes.pack bytes
          encoded = Sdk.serialise payload
      validGeneralisedUtf8 payload @?= True
      legacy <- right (Sdk.deserialiseOrFail encoded :: Either Sdk.DeserialiseFailure String)
      generalisedUtf8ScalarCount payload @?= Just (fromIntegral (length legacy))
      decoded <- right (Sdk.deserialiseOrFail encoded)
      serialiseStringValue decoded @?= legacy
      Sdk.serialise decoded @?= Sdk.serialise legacy
  it "claimed payload lengths cannot create an absent one-GiB field" $
    forM_ [Bytes.pack [0x5a, 0x40, 0, 0, 0], Bytes.pack [0x7a, 0x40, 0, 0, 0]] $ \encoded ->
      assertBool
        "missing claimed payload was accepted"
        ( isLeft
            ( Sdk.deserialiseOrFail (Data.ByteString.Lazy.fromStrict encoded)
                :: Either Sdk.DeserialiseFailure SerialiseString
            )
        )
  it "byte payload arrays copy only the visible slice" $
    forM_ [[], "ascii", ['\955', '\x1f642'], [chr 0xd800], ['a', chr 0xdfff, '\x1f642']] $ \original -> do
      payload <- stringPayload (Sdk.serialise original)
      let wire = Data.ByteString.Lazy.toStrict (Sdk.serialise payload)
          backing = Bytes.replicate 513 0 <> wire <> Bytes.replicate 31 0
          selected = Bytes.take (Bytes.length wire) (Bytes.drop 513 backing)
      decoded <- right (Sdk.deserialiseOrFail (Data.ByteString.Lazy.fromStrict selected))
      serialiseStringValue decoded @?= original
  it "segmented byte fields use the same checked SDK String domain" $
    forM_ [[], "ascii", ['\955', '\x1f642'], [chr 0xd800], ['a', chr 0xdfff, '\x1f642']] $ \original -> do
      payload <- stringPayload (Sdk.serialise original)
      let wire = Data.ByteString.Lazy.toStrict (Sdk.serialise payload)
      forM_ [0 .. Bytes.length wire] $ \cut -> do
        decoded <-
          right
            ( Sdk.deserialiseOrFail
                (Data.ByteString.Lazy.fromChunks [Bytes.take cut wire, Bytes.drop cut wire])
            )
        serialiseStringValue decoded @?= original

-- Observe the pinned SDK's actual payload domain independently of the counter.
stringPayload :: Data.ByteString.Lazy.ByteString -> IO Bytes.ByteString
stringPayload encoded = do
  value <- right (Sdk.deserialiseOrFail encoded)
  case value of
    Term.TString text -> pure (Text.encodeUtf8 text)
    Term.TBytes bytes -> pure bytes
    _ -> fail "SDK String no longer uses a text or byte payload"
