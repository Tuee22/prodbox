{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}

module AwsSubstrateCidrTests (awsSubstrateCidrSuite, cidrReferenceInputs, projectCidr) where

import Control.Exception (evaluate)
import Control.Monad (forM, forM_)
import Data.Bits (shiftR, (.&.))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import FrozenAwsSubstrateCidr (frozenParseAwsCidr)
import PinnedHeapGraph (observeGraph, observedDataBytes)
import Prodbox.Settings.AwsSubstrateCidr
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

awsSubstrateCidrSuite :: SuiteBuilder ()
awsSubstrateCidrSuite = describe "bounded AWS profile IPv4 CIDR scanner" $ do
  it "preserves explicit address and prefix boundaries" $
    forM_ examples $
      \(input, expected) -> projectCidr input @?= expected
  it "agrees with the frozen parser on every three-digit octet value in every position" $ do
    forM_ octetInputs compareReference
    print ("cidr_octet_reference_cases" :: String, length octetInputs)
  it "agrees on prefix values and all one-to-three-digit prefix spellings" $ do
    forM_ prefixInputs compareReference
    print ("cidr_prefix_reference_cases" :: String, length prefixInputs)
  it "reconstructs addresses independently across every prefix and retained leading zeros" $ do
    forM_ addressCases $ \(address, prefix, input) -> do
      projectCidr input @?= Just (toInteger address, prefix)
      compareReference input
    print ("cidr_address_roundtrip_cases" :: String, length addressCases)
  it "refuses malformed separators octet zeros internal spaces NUL and non-ASCII digits" $ do
    forM_ malformedInputs $ \input -> do
      projectCidr input @?= Nothing
      compareReference input
    print ("cidr_malformed_cases" :: String, length malformedInputs)
  it "retains Unicode outer whitespace handling and rejects interior whitespace" $ do
    forM_ whitespaceInputs compareReference
    print ("cidr_whitespace_reference_cases" :: String, length whitespaceInputs)
  it "derives the scan budget from the complete existing grammar" $ do
    awsCidrMaximumCharacters @?= 19
    awsCidrScanSteps @?= 20
    let longest = "255.255.255.255/032"
    Text.length longest @?= awsCidrMaximumCharacters
    projectCidr longest @?= Just (4294967295, 32)
    projectCidr (longest <> "0") @?= Nothing
  it "returns evaluated numeric data without retaining the input Text" $ do
    sizes <- forM ["0.0.0.0/000", "203.0.113.44/032", "255.255.255.255/32"] $ \input -> do
      parsed <-
        maybe (assertFailure "expected a valid CIDR" >> fail "unreachable") pure (parseAwsCidr input)
      evaluated <- evaluate parsed
      graph <- observeGraph evaluated
      observedDataBytes graph @?= 24
      pure (observedDataBytes graph)
    print ("cidr_result_data_bytes" :: String, sizes)

projectCidr :: Text -> Maybe (Integer, Int)
projectCidr = fmap (\parsed -> (awsCidrAddress parsed, awsCidrPrefix parsed)) . parseAwsCidr
compareReference :: Text -> IO ()
compareReference input = assertEqual (show input) (frozenParseAwsCidr input) (projectCidr input)

examples :: [(Text, Maybe (Integer, Int))]
examples =
  [ ("0.0.0.0/0", Just (0, 0))
  , ("0.0.0.0/000", Just (0, 0))
  , ("255.255.255.255/032", Just (4294967295, 32))
  , ("203.0.113.44/32", Just (3405803820, 32))
  , (" 203.0.113.44/032 ", Just (3405803820, 32))
  , ("1.2.3.4/00", Just (16909060, 0))
  , ("1.2.3.4/33", Nothing)
  , ("01.2.3.4/32", Nothing)
  , ("1.2.3.4/", Nothing)
  ]

octetInputs :: [Text]
octetInputs =
  [ Text.intercalate
      "."
      [if slot == selected then Text.pack (show value) else "1" | slot <- [0 .. 3 :: Int]]
      <> "/32"
  | selected <- [0 .. 3 :: Int]
  , value <- [0 .. 999 :: Int]
  ]

prefixInputs :: [Text]
prefixInputs = ["203.0.113.44/" <> pad width value | width <- [1 .. 3], value <- [0 .. 999]]

addressCases :: [(Word32, Int, Text)]
addressCases =
  [ (address, prefix, renderAddress address <> "/" <> pad width prefix)
  | seed <- [0 .. 255 :: Word32]
  , let address = seed * 16843009
  , prefix <- [0 .. 32]
  , width <- [1 .. 3]
  ]

renderAddress :: Word32 -> Text
renderAddress address = Text.intercalate "." [Text.pack (show (shiftR address shift .&. 255)) | shift <- [24, 16, 8, 0]]
pad :: Int -> Int -> Text
pad width value =
  let digits = Text.pack (show value)
   in Text.replicate (max 0 (width - Text.length digits)) "0" <> digits

malformedInputs :: [Text]
malformedInputs =
  [ ""
  , "/0"
  , "1/0"
  , "1.2/0"
  , "1.2.3/0"
  , "1.2.3.4.5/0"
  , "1.2.3.4//0"
  , "1..3.4/0"
  , ".1.2.3/0"
  , "1.2.3./0"
  , "1.2.3.4/-1"
  , "1.2.3.4/+1"
  , "1.2.3.4/0000"
  , "1.2.3.4/0/0"
  , "1.2.3.4/32x"
  , "1.2.3.4 /32"
  , "1.2.3.4/ 32"
  , "1. 2.3.4/32"
  , "001.2.3.4/0"
  , "1.02.3.4/0"
  , "1.2.003.4/0"
  , "1.2.3.00/0"
  , "256.0.0.0/0"
  , "-1.2.3.4/0"
  , "1.2.3.4/\0"
  , "١.2.3.4/0"
  , "1.2.3.4/٣٢"
  , "１.2.3.4/0"
  ]

whitespaceInputs :: [Text]
whitespaceInputs =
  [ left <> body <> right
  | left <- ["", " ", "\t\n", "\x2003"]
  , right <- ["", " ", "\r\n", "\x2003"]
  , body <- ["203.0.113.44/032", "1.2.3.4/00", "1. 2.3.4/32"]
  ]

cidrReferenceInputs :: [Text]
cidrReferenceInputs =
  map fst examples
    <> octetInputs
    <> prefixInputs
    <> map (\(_, _, input) -> input) addressCases
    <> malformedInputs
    <> whitespaceInputs
