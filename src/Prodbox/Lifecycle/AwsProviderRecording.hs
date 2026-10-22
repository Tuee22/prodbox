{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Promotion boundary for provider transcripts. Origins distinguish a live
-- observation from a hand transcription, a CLI loopback and a timing assumption.
-- Only the opaque scrubbed value can be rendered for a repository fixture.
module Prodbox.Lifecycle.AwsProviderRecording
  ( RecordingOrigin (..)
  , ProviderRecordedCall (..)
  , ProviderTranscript (..)
  , ScrubbedProviderRecording
  , scrubProviderRecording
  , scrubbedProviderRecordingBytes
  , recordingScrubberVersion
  , maximumCanaryPlantEvidenceCharacters
  , canaryPlantRecordingEvidence
  , canaryPlantRecordingFromEvidence
  ) where

import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecodeStrict', encode, object, (.:), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAlphaNum, isAscii, isDigit)
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Aws.CliError (awsCliServiceErrorMatches)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

data RecordingOrigin
  = OperatorInventoryTranscription !Text
  | LiveCanaryCapture
  | InstalledCliLoopback !Text
  | AssumedProviderBehaviour !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- The operation is metadata, never a command line or environment. Relative
-- delays and call order survive promotion unchanged; payloads are scrubbed.
data ProviderRecordedCall = ProviderRecordedCall
  { recordedOperation :: !Text
  , recordedDelayMicros :: !Natural
  , recordedExitCode :: !Int
  , recordedStdout :: !Text
  , recordedStderr :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ProviderTranscript = ProviderTranscript
  { transcriptOrigin :: !RecordingOrigin
  , transcriptCalls :: ![ProviderRecordedCall]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ScrubbedProviderRecording = ScrubbedProviderRecording ByteString
  deriving stock (Eq, Show)

scrubbedProviderRecordingBytes :: ScrubbedProviderRecording -> ByteString
scrubbedProviderRecordingBytes (ScrubbedProviderRecording bytes) = bytes

recordingScrubberVersion :: Text
recordingScrubberVersion = "prodbox-provider-recording/v1"

-- Two complete dependency errors and their call metadata, never truncated.
-- Base64 is printable under the Provider evidence framing. The maximum is
-- derived from the byte envelope and prefix, rather than a second size guess.
canaryRecordingMaximumBytes :: Int
canaryRecordingMaximumBytes = 12 * 1024

canaryEvidencePrefix :: Text
canaryEvidencePrefix = "prodbox-test-canary|groups=3|interfaces=1|dependency-probes=2|recording="

maximumCanaryPlantEvidenceCharacters :: Int
maximumCanaryPlantEvidenceCharacters = Text.length canaryEvidencePrefix + 4 * ((canaryRecordingMaximumBytes + 2) `div` 3)

canaryPlantRecordingEvidence :: ScrubbedProviderRecording -> Either Text Text
canaryPlantRecordingEvidence recording = do
  let bytes = scrubbedProviderRecordingBytes recording
      evidence = canaryEvidencePrefix <> TextEncoding.decodeUtf8 (Base64.encode bytes)
  _ <- canaryPlantRecordingFromEvidence evidence
  Right evidence

canaryPlantRecordingFromEvidence :: Text -> Either Text ScrubbedProviderRecording
canaryPlantRecordingFromEvidence evidence = do
  payload <-
    maybe
      (Left "test canary evidence has another shape")
      Right
      (Text.stripPrefix canaryEvidencePrefix evidence)
  bytes <-
    first
      (const "test canary recording is not base64")
      (Base64.decode (TextEncoding.encodeUtf8 payload))
  unless
    ( ByteString.length bytes <= canaryRecordingMaximumBytes
        && Base64.encode bytes == TextEncoding.encodeUtf8 payload
    )
    (Left "test canary recording exceeds its byte bound or is not canonical base64")
  value <- first (const "test canary recording is not JSON") (eitherDecodeStrict' bytes)
  (version, digest, transcript) <-
    first (const "test canary recording envelope is malformed") (parseEither envelope value)
  unless
    ( version == recordingScrubberVersion
        && digest == TextEncoding.decodeUtf8 (hexSha256 (LazyByteString.toStrict (encode transcript)))
    )
    (Left "test canary recording version or payload digest does not match")
  unless
    (transcriptOrigin transcript == LiveCanaryCapture)
    (Left "test canary evidence requires an actual canary capture")
  let calls = transcriptCalls transcript
  unless
    (map recordedOperation calls == ["delete-security-group:held", "delete-security-group:left"])
    (Left "test canary recording does not contain the two ordered dependency probes")
  unless
    (all validProbe calls)
    (Left "test canary recording does not confirm both dependency refusals")
  let expected =
        object
          [ "scrubber" .= version
          , "payload_sha256" .= digest
          , "transcript" .= transcript
          ]
  unless
    (value == expected && LazyByteString.toStrict (encode expected) == bytes)
    (Left "test canary recording is not the exact canonical JSON shape")
  Right (ScrubbedProviderRecording bytes)
 where
  envelope value = case value of
    Object fields
      | KeyMap.size fields == 3 ->
          (,,) <$> fields .: "scrubber" <*> fields .: "payload_sha256" <*> fields .: "transcript"
    _ -> fail "expected the complete recording envelope"
  validProbe call =
    Text.null (recordedStdout call)
      && recordedExitCode call >= 1
      && recordedExitCode call <= 255
      && ByteString.length (TextEncoding.encodeUtf8 (recordedStderr call)) <= 4096
      && not (containsCredential (recordedStderr call))
      && awsCliServiceErrorMatches
        "DependencyViolation"
        "DeleteSecurityGroup"
        (ProcessOutput (ExitFailure (recordedExitCode call)) "" (Text.unpack (recordedStderr call)))

-- | Explicit substitutions cover operator-authored names (domains, buckets,
-- principal names). EC2 ids, accounts, ARNs, IPs and request ids are discovered
-- independently. Credentials cause refusal, rather than being promoted.
scrubProviderRecording
  :: [(Text, Text)]
  -> ProviderTranscript
  -> Either Text ScrubbedProviderRecording
scrubProviderRecording substitutions transcript = do
  let calls = transcriptCalls transcript
      payloads =
        originFields (transcriptOrigin transcript)
          ++ concatMap (\call -> [recordedStdout call, recordedStderr call]) calls
  unless
    (not (null calls) && length calls <= 64)
    (Left "provider recording must contain between one and 64 calls")
  unless
    (all validOperation calls)
    (Left "provider recording operation must be metadata, not a command or coordinate")
  unless
    (all ((<= 65536) . ByteString.length . TextEncoding.encodeUtf8) payloads)
    (Left "provider recording payload exceeds 64 KiB; it is not silently truncated")
  unless
    (sum (map (ByteString.length . TextEncoding.encodeUtf8) payloads) <= 128 * 1024)
    (Left "provider recording input exceeds 128 KiB")
  unless
    (all (not . containsCredential) payloads)
    (Left "provider recording contains credential-shaped material")
  unless
    (validSubstitutions substitutions)
    (Left "provider recording explicit substitutions must be unique, nonempty reserved example values")
  let discovered = nub (concatMap discover payloads)
      automatic = zipWith reservedPair [1 ..] discovered
      replacements = sortOn (Down . Text.length . fst) (substitutions ++ automatic)
      scrub = replaceAll replacements
      scrubbedCalls =
        map
          ( \call ->
              call {recordedStdout = scrub (recordedStdout call), recordedStderr = scrub (recordedStderr call)}
          )
          calls
      body =
        transcript
          { transcriptOrigin = scrubOrigin scrub (transcriptOrigin transcript)
          , transcriptCalls = scrubbedCalls
          }
      bodyBytes = LazyByteString.toStrict (encode body)
      bytes =
        LazyByteString.toStrict $
          encode $
            object
              [ "scrubber" .= recordingScrubberVersion
              , "payload_sha256" .= TextEncoding.decodeUtf8 (hexSha256 bodyBytes)
              , "transcript" .= body
              ]
  unless
    (ByteString.length bytes <= 128 * 1024)
    (Left "scrubbed provider recording exceeds 128 KiB; it is not silently truncated")
  -- A replacement must not introduce credential-shaped data either.
  unless
    (all ((not . containsCredential) . snd) replacements)
    (Left "provider recording replacement contains credential-shaped material")
  Right (ScrubbedProviderRecording bytes)
 where
  validOperation call =
    let operation = recordedOperation call
     in not (Text.null operation)
          && Text.length operation <= 128
          && null (discover operation)
          && not (containsCredential operation)
          && Text.all (\char -> isAscii char && (isAlphaNum char || char `elem` ("-:." :: String))) operation

validSubstitutions :: [(Text, Text)] -> Bool
validSubstitutions substitutions =
  length substitutions <= 128
    && length (nub (map fst substitutions)) == length substitutions
    && all
      (\(raw, replacement) -> not (Text.null raw) && Text.length raw <= 4096 && reserved replacement)
      substitutions
 where
  reserved value =
    Text.isInfixOf "example.test" value
      || Text.isPrefixOf "recording-" value

containsCredential :: Text -> Bool
containsCredential value =
  any
    (`Text.isInfixOf` Text.toLower value)
    [ "aws_secret_access_key"
    , "aws_session_token"
    , "x-amz-security-token"
    , "authorization:"
    , "-----begin private key"
    ]
    || any isAccessKey (Text.words (Text.map separate value))
 where
  separate char
    | isAscii char && isAlphaNum char = char
    | otherwise = ' '
  isAccessKey token = Text.length token == 20 && any (`Text.isPrefixOf` token) ["AKIA", "ASIA"]

-- Tokens retain ARN punctuation, so an entire ARN is replaced together. Plain
-- JSON punctuation is a separator and cannot hide an account or EC2 id.
originFields :: RecordingOrigin -> [Text]
originFields origin = case origin of
  OperatorInventoryTranscription detail -> [detail]
  LiveCanaryCapture -> []
  InstalledCliLoopback detail -> [detail]
  AssumedProviderBehaviour detail -> [detail]

scrubOrigin :: (Text -> Text) -> RecordingOrigin -> RecordingOrigin
scrubOrigin scrub origin = case origin of
  OperatorInventoryTranscription detail -> OperatorInventoryTranscription (scrub detail)
  LiveCanaryCapture -> LiveCanaryCapture
  InstalledCliLoopback detail -> InstalledCliLoopback (scrub detail)
  AssumedProviderBehaviour detail -> AssumedProviderBehaviour (scrub detail)

discover :: Text -> [Text]
discover value = arns ++ ec2Ids ++ accounts ++ filter otherSensitive tokens
 where
  arns =
    [ Text.dropWhileEnd (`elem` (".:/" :: String)) (Text.takeWhile tokenChar suffix)
    | (_, suffix) <- Text.breakOnAll "arn:" value
    ]
  ec2Ids =
    [ prefix <> suffix
    | prefix <- ec2Prefixes
    , (_, remainder) <- Text.breakOnAll prefix value
    , let suffix = Text.takeWhile hexChar (Text.drop (Text.length prefix) remainder)
    , Text.length suffix `elem` [8, 17]
    ]
  accounts = filter ((== 12) . Text.length) (Text.split (not . isDigit) value)
  tokens =
    map
      (Text.dropAround (`elem` (".:/" :: String)))
      (Text.words (Text.map (\char -> if tokenChar char then char else ' ') value))
  tokenChar char = isAscii char && (isAlphaNum char || char `elem` ("-._:/@" :: String))
  hexChar char = char `elem` ("0123456789abcdefABCDEF" :: String)
  otherSensitive token = ipv4 token || uuid token
  ipv4 token = case Text.splitOn "." token of
    [a, b, c, d] -> all octet [a, b, c, d]
    _ -> False
  octet text = not (Text.null text) && Text.length text <= 3 && Text.all isDigit text && decimal text <= 255
  decimal = Text.foldl' (\number char -> number * 10 + fromEnum char - fromEnum '0') (0 :: Int)
  uuid token =
    map Text.length (Text.splitOn "-" token) == [8, 4, 4, 4, 12]
      && Text.all (\char -> char == '-' || hexChar char) token

ec2Prefixes :: [Text]
ec2Prefixes =
  [ "eni-attach-"
  , "eipalloc-"
  , "eipassoc-"
  , "subnet-"
  , "vpce-"
  , "vpc-"
  , "eni-"
  , "sg-"
  , "i-"
  , "igw-"
  , "rtb-"
  , "nat-"
  , "vol-"
  , "snap-"
  , "lt-"
  ]

ec2Identifier :: Text -> Bool
ec2Identifier token = any matching ec2Prefixes
 where
  matching prefix = case Text.stripPrefix prefix token of
    Just suffix ->
      Text.length suffix `elem` [8, 17] && Text.all (`elem` ("0123456789abcdefABCDEF" :: String)) suffix
    Nothing -> False

reservedPair :: Int -> Text -> (Text, Text)
reservedPair index token = (token, replacement)
 where
  counter = Text.pack (show index)
  hex = Text.pack (showHex index "")
  replacement
    | Text.isPrefixOf "arn:" token =
        "arn:aws:ec2:" <> awsGlobalServiceRegion <> ":123456789012:recorded-resource/recording-" <> counter
    | ec2Identifier token =
        case [prefix | prefix <- ec2Prefixes, prefix `Text.isPrefixOf` token] of
          prefix : _ -> prefix <> Text.replicate (17 - Text.length hex) "0" <> hex
          [] -> "recording-resource-" <> counter
    | Text.length token == 12 && Text.all isDigit token = "123456789012"
    | Text.isInfixOf "." token = "192.0.2." <> Text.pack (show (1 + index `mod` 253))
    | otherwise = "00000000-0000-4000-8000-" <> Text.replicate (12 - Text.length hex) "0" <> hex

-- Simultaneous replacement avoids cascading a reserved value through another
-- substitution or conflating two source identifiers. Longest match wins.
replaceAll :: [(Text, Text)] -> Text -> Text
replaceAll replacements = Text.concat . go
 where
  indexed = Map.fromList (reverse replacements)
  ordered = map fst replacements
  go input
    | Text.null input = []
    | otherwise = case [ (raw, replacement)
                       | raw <- ordered
                       , raw `Text.isPrefixOf` input
                       , Just replacement <- [Map.lookup raw indexed]
                       ] of
        (raw, replacement) : _ -> replacement : go (Text.drop (Text.length raw) input)
        [] -> case Text.uncons input of
          Nothing -> []
          Just (char, rest) -> Text.singleton char : go rest
