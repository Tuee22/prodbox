{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Only public synthetic provenance is decoded here; no ownership is minted.
module Main (main) where

import Codec.CBOR.Term (Term (..))
import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (chr)
import Data.Either (isLeft)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word32, Word64, Word8)
import GHC.Generics (Generic)
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublicationRecord qualified as Birth
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Test.Tasty
import Test.Tasty.HUnit

-- Independent mirrors of the existing v1 Generic wire product, not constructors
-- for any native provenance or capability. Constructor names are absent on wire.
data Parent = Parent Integer Integer Integer Integer deriving (Generic, Serialise)
data File
  = File Integer Integer Integer Integer Integer Integer Integer (Integer, Integer) (Integer, Integer)
  deriving (Generic, Serialise)
type Metadata = (Word8, FilePath, Parent, File)
data Submission
  = Submission Word8 String [Word64] String String String Word32 Word32 Word64 String [Metadata]
  deriving (Generic, Serialise)
data Anonymous = Anonymous Parent File File deriving (Generic, Serialise)

key :: String
key = replicate 64 'a'

parent :: Parent
parent = Parent 1 11 1000 0o40700

file :: Integer -> Integer -> File
file ino links = File 1 ino 0 0o100400 1000 1000 links (1, 1) (1, 1)

metadata :: String -> [Metadata]
metadata suffix =
  [ (role, "/synthetic/" <> show role <> suffix, parent, file (20 + toInteger role) 1)
  | role <- [0, 1, 2]
  ]

submissionPrefix, birthPrefix, kindPrefix :: ByteString
submissionPrefix = "prodbox-host-controller-submission/v1\NUL"
birthPrefix = "prodbox-host-controller-publication/birth/v2\NUL"
kindPrefix = "prodbox-host-controller-publication/birth/kind/v1\NUL"

submissionPayload :: String -> ByteString
submissionPayload suffix =
  Lazy.toStrict
    ( serialise
        ( Submission
            1
            key
            [200, 100, 120, 140, 160]
            "11111111-1111-1111-1111-111111111111"
            (replicate 32 '1')
            ":1.2"
            1000
            42
            11
            ":1.3"
            (metadata suffix)
        )
    )

anonymous :: ByteString
anonymous = Lazy.toStrict (serialise (Anonymous parent (file 31 0) (file 32 0)))

birthPayload :: ByteString
birthPayload =
  Lazy.toStrict
    ( serialise
        ( 2 :: Word8
        , key
        , 100 :: Word64
        , anonymous
        , (1, 40, 1000, 1000, 0o100400) :: (Integer, Integer, Integer, Integer, Integer)
        )
    )

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

term :: ByteString -> IO Term
term = right . deserialiseOrFail . Lazy.fromStrict

rewrite :: [Int] -> Term -> Term -> Either String Term
rewrite [] replacement _ = Right replacement
rewrite (index : rest) replacement value = case value of
  TList values -> TList <$> update values
  TListI values -> TListI <$> update values
  _ -> Left "fixture coordinate is not a list"
 where
  update values = case splitAt index values of
    (prefix, selected : suffix) | index >= 0 -> do
      updated <- rewrite rest replacement selected
      pure (prefix <> [updated] <> suffix)
    _ -> Left "fixture coordinate is absent"

changed :: ByteString -> [Int] -> Term -> IO ByteString
changed payload path replacement = Lazy.toStrict . serialise <$> (right . rewrite path replacement =<< term payload)

submissionStrings :: [[Int]]
submissionStrings = [[2], [4], [5], [6], [10], [11, 0, 1], [11, 1, 1], [11, 2, 1]]

malformed :: [[Word8]]
malformed =
  [ [0x80]
  , [0xc2]
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

expectedFingerprint :: String -> String
expectedFingerprint suffix = concatMap hex (BS.unpack digest)
 where
  digest =
    SHA256.hash
      (Lazy.toStrict (serialise ("prodbox-host-controller-input-metadata/v1" :: Text, metadata suffix)))
  hex byte =
    [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
    , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
    ]

main :: IO ()
main =
  defaultMain $
    testGroup
      "native provenance String codecs"
      [ testCase "legacy submissions keep exact bytes and independent fingerprints" $
          forM_ [".bin", "-λ-😀", ['-', chr 0xdc80], replicate 4084 'x'] $ \suffix -> do
            let bytes = submissionPrefix <> submissionPayload suffix
            decoded <- right (Inputs.decodeHostControllerSubmission bytes)
            Inputs.encodeHostControllerSubmission decoded @?= bytes
            Identity.hostExecutionKeyText (Inputs.hostControllerSubmissionKey decoded) @?= key
            Inputs.hostControllerInputFingerprintText (Inputs.hostControllerSubmissionFingerprint decoded)
              @?= expectedFingerprint suffix
      , testCase "every submission String rejects malformed generalized UTF8" $
          forM_ submissionStrings $ \path -> forM_ malformed $ \payload -> do
            bytes <- changed (submissionPayload ".bin") path (TBytes (BS.pack payload))
            assertBool
              "malformed native submission accepted"
              (isLeft (Inputs.decodeHostControllerSubmission (submissionPrefix <> bytes)))
      , testCase "valid UTF8 byte fields retain submission canonicality refusal" $
          forM_ submissionStrings $ \path -> do
            original <- term (submissionPayload "-λ")
            value <- right (lookupAt path original)
            case value of
              TString text -> do
                bytes <- changed (submissionPayload "-λ") path (TBytes (Text.encodeUtf8 text))
                assertBool
                  "noncanonical native String accepted"
                  (isLeft (Inputs.decodeHostControllerSubmission (submissionPrefix <> bytes)))
              _ -> assertFailure "fixture String encoding changed"
      , testCase "publication records keep legacy and ordinary exact bytes"
          $ forM_
            [ birthPrefix <> birthPayload
            , kindPrefix <> Lazy.toStrict (serialise (1 :: Word8, 1 :: Word8, birthPrefix <> birthPayload))
            ]
          $ \bytes -> do
            decoded <-
              maybe (fail "valid publication fixture refused") pure (Birth.decodePublicationBirth bytes)
            Birth.encodePublicationBirth decoded @?= bytes
            Identity.hostExecutionKeyText (Birth.publicationBirthKey decoded) @?= key
            Birth.publicationBirthWorkEnd decoded @?= 100
      , testCase "publication String rejects malformed generalized UTF8" $
          forM_ malformed $ \payload -> do
            bytes <- changed birthPayload [1] (TBytes (BS.pack payload))
            assertBool
              "malformed publication accepted"
              (isNothing (Birth.decodePublicationBirth (birthPrefix <> bytes)))
      , testCase "valid UTF8 byte field retains publication canonicality refusal" $ do
          bytes <- changed birthPayload [1] (TBytes (Text.encodeUtf8 (Text.pack key)))
          assertBool
            "noncanonical publication String accepted"
            (isNothing (Birth.decodePublicationBirth (birthPrefix <> bytes)))
      , testCase "native record ceilings and trailing-data checks remain enforced" $ do
          forM_
            [ BS.replicate 65537 0
            , submissionPrefix <> submissionPayload ".bin" <> "\NUL"
            , submissionPrefix <> BS.init (submissionPayload ".bin")
            ]
            $ \bytes ->
              assertBool
                "invalid submission framing accepted"
                (isLeft (Inputs.decodeHostControllerSubmission bytes))
          forM_
            [BS.replicate 8193 0, birthPrefix <> birthPayload <> "\NUL", birthPrefix <> BS.init birthPayload]
            $ \bytes ->
              assertBool "invalid publication framing accepted" (isNothing (Birth.decodePublicationBirth bytes))
      ]

lookupAt :: [Int] -> Term -> Either String Term
lookupAt [] value = Right value
lookupAt (index : rest) value = case value of
  TList values -> select values
  TListI values -> select values
  _ -> Left "fixture coordinate is not a list"
 where
  select values = case drop index values of
    selected : _ | index >= 0 -> lookupAt rest selected
    _ -> Left "fixture coordinate is absent"
