{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsProviderRecording (awsProviderRecordingSuite) where

import AwsCanaryFixtures
import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Lifecycle.AwsProviderRecording
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import TestSupport

awsProviderRecordingSuite :: SuiteBuilder ()
awsProviderRecordingSuite = describe "Sprint 5.59 provider recording promotion" $ do
  it "removes real-shaped accounts, EC2 coordinates, ARNs, IPs, request ids and declared names" $ do
    let account = Text.replicate 12 "9"
        eni = "eni-0abcdef1234567890"
        group = "sg-0fedcba9876543210"
        arn = "arn:aws:iam::" <> account <> ":role/source-principal"
        requestId = "aabbccdd-1234-4321-8888-123456789abc"
        raw =
          "DependencyViolation: resource "
            <> group
            <> ": interface "
            <> eni
            <> ". Account:"
            <> account
            <> " "
            <> arn
            <> " 10.42.7.8 "
            <> requestId
            <> ". source.invalid source-bucket"
        call = ProviderRecordedCall "delete-security-group" 987654 254 "" raw
        source = ProviderTranscript (OperatorInventoryTranscription "2026-10-14") [call, call]
        recording =
          must
            ( scrubProviderRecording
                [("source.invalid", "example.test"), ("source-bucket", "recording-bucket")]
                source
            )
        bytes = scrubbedProviderRecordingBytes recording
        rendered = TextEncoding.decodeUtf8 bytes
    forM_
      [ account
      , eni
      , group
      , arn
      , requestId
      , "10.42.7.8"
      , "source.invalid"
      , "source-bucket"
      , "source-principal"
      ]
      $ \value ->
        rendered `shouldSatisfy` (not . Text.isInfixOf value)
    rendered `shouldSatisfy` Text.isInfixOf "DependencyViolation: resource sg-"
    rendered `shouldSatisfy` Text.isInfixOf "OperatorInventoryTranscription"
    rendered `shouldSatisfy` Text.isInfixOf "2026-10-14"
    let calls = recordingCalls bytes
    length calls `shouldBe` 2
    calls `shouldSatisfy` all (hasField "recordedDelayMicros" (Number 987654))
    calls `shouldSatisfy` all (hasField "recordedExitCode" (Number 254))
    calls `shouldSatisfy` all (hasField "recordedOperation" (String "delete-security-group"))
    calls `shouldSatisfy` equalRecordedPair
  it "replaces repeated and overlapping names simultaneously without cascading example values" $ do
    let call = ProviderRecordedCall "describe-vpcs" 0 0 "source/long source source/long" ""
        bytes =
          scrubbedProviderRecordingBytes $
            must $
              scrubProviderRecording
                [("source/long", "recording-long"), ("source", "recording-short"), ("recording", "recording-again")]
                (ProviderTranscript (InstalledCliLoopback "2.34.18") [call])
    recordingCalls bytes
      `shouldSatisfy` all (hasField "recordedStdout" (String "recording-long recording-short recording-long"))
  forM_
    [ "aws_secret_access_key=value"
    , "AWS_SESSION_TOKEN=value"
    , "x-amz-security-token: value"
    , "Authorization: AWS4-HMAC-SHA256 value"
    , "-----BEGIN PRIVATE KEY-----"
    , "AKIA" <> Text.replicate 16 "A"
    , "ASIA" <> Text.replicate 16 "B"
    ]
    $ \credential ->
      it ("refuses credential-shaped payload " ++ show (Text.take 20 credential)) $ do
        let call = ProviderRecordedCall "describe-vpcs" 0 0 credential ""
        scrubProviderRecording
          []
          (ProviderTranscript (AssumedProviderBehaviour "authored-unit-case") [call])
          `shouldSatisfy` isLeft
  it "bounds input bytes, call count, operations and the explicit substitution table" $ do
    let call = ProviderRecordedCall "describe-vpcs" 0 0 "" ""
        transcript calls = ProviderTranscript (AssumedProviderBehaviour "authored-unit-case") calls
    scrubProviderRecording [] (transcript []) `shouldSatisfy` isLeft
    scrubProviderRecording [] (transcript (replicate 65 call)) `shouldSatisfy` isLeft
    scrubProviderRecording [] (transcript [call {recordedOperation = Text.replicate 12 "9"}])
      `shouldSatisfy` isLeft
    scrubProviderRecording
      []
      (transcript [call {recordedOperation = "aws ec2 describe-vpcs --profile private"}])
      `shouldSatisfy` isLeft
    scrubProviderRecording [] (transcript [call {recordedStdout = Text.replicate 65537 "x"}])
      `shouldSatisfy` isLeft
    scrubProviderRecording [("", "recording-empty")] (transcript [call]) `shouldSatisfy` isLeft
    scrubProviderRecording [("source", "unreserved-private-value")] (transcript [call])
      `shouldSatisfy` isLeft
    scrubProviderRecording [("source", "recording-a"), ("source", "recording-b")] (transcript [call])
      `shouldSatisfy` isLeft
  it "seals both ordered dependency errors as printable bounded plant evidence" $ do
    let intent = PlantTestVpcCanary fixtureCanaryReference fixtureCanaryRequest
        recording = must (canaryPlantRecordingFromEvidence fixtureCanaryEvidence)
    validateProviderIntentEvidence intent fixtureCanaryEvidence `shouldBe` Right fixtureCanaryEvidence
    canaryPlantRecordingEvidence recording `shouldBe` Right fixtureCanaryEvidence
    Text.length fixtureCanaryEvidence `shouldSatisfy` (<= maximumCanaryPlantEvidenceCharacters)
    providerIntentEvidenceMaximumCharacters intent `shouldBe` maximumCanaryPlantEvidenceCharacters
    maximumCanaryPlantEvidenceCharacters `shouldSatisfy` (< 64 * 1024)
    fixtureCanaryEvidence `shouldSatisfy` Text.all (\char -> char >= ' ' && char /= '\DEL')
  forM_
    [ "success"
    , "invalid-exit-code"
    , "wrong-code"
    , "wrong-operation"
    , "swapped"
    , "missing"
    , "hand-transcribed"
    , "assumption"
    ]
    $ \fault ->
      it ("refuses a canary qualification recording with " ++ Text.unpack fault) $ do
        let calls = transcriptCalls fixtureCanaryTranscript
            changed = case calls of
              [held, left] -> case fault of
                "success" -> fixtureCanaryTranscript {transcriptCalls = [held {recordedExitCode = 0}, left]}
                "invalid-exit-code" -> fixtureCanaryTranscript {transcriptCalls = [held {recordedExitCode = 999}, left]}
                "wrong-code" ->
                  fixtureCanaryTranscript
                    { transcriptCalls =
                        [ held {recordedStderr = Text.replace "DependencyViolation" "AccessDenied" (recordedStderr held)}
                        , left
                        ]
                    }
                "wrong-operation" ->
                  fixtureCanaryTranscript
                    { transcriptCalls =
                        [ held
                            { recordedStderr = Text.replace "DeleteSecurityGroup" "DeleteNetworkInterface" (recordedStderr held)
                            }
                        , left
                        ]
                    }
                "swapped" -> fixtureCanaryTranscript {transcriptCalls = [left, held]}
                "missing" -> fixtureCanaryTranscript {transcriptCalls = [held]}
                "hand-transcribed" -> fixtureCanaryTranscript {transcriptOrigin = OperatorInventoryTranscription "2026-10-14"}
                _ -> fixtureCanaryTranscript {transcriptOrigin = AssumedProviderBehaviour "authored-unit-case"}
              _ -> error "two authored probe fixtures required"
        (scrubProviderRecording [] changed >>= canaryPlantRecordingEvidence) `shouldSatisfy` isLeft
  it "refuses malformed evidence, a changed digest, oversize bytes and extra envelope fields" $ do
    let recording = must (canaryPlantRecordingFromEvidence fixtureCanaryEvidence)
        value = must (eitherDecodeStrict' (scrubbedProviderRecordingBytes recording))
        changed = case value of
          Object fields -> Object (KeyMap.insert "unexpected" Null fields)
          _ -> error "recording object required"
        nestedChanged = case value of
          Object fields -> case KeyMap.lookup "transcript" fields of
            Just (Object transcript) ->
              Object
                ( KeyMap.insert
                    "transcript"
                    (Object (KeyMap.insert "unexpected" (String "unowned-data") transcript))
                    fields
                )
            _ -> error "transcript object required"
          _ -> error "recording object required"
        prefix = "prodbox-test-canary|groups=3|interfaces=1|dependency-probes=2|recording="
        wire bytes = prefix <> TextEncoding.decodeUtf8 (Base64.encode bytes)
    forM_
      [ ""
      , fixtureCanaryEvidence <> "="
      , wire (LazyByteString.toStrict (encode changed))
      , wire (LazyByteString.toStrict (encode nestedChanged))
      , wire (ByteString.replicate (12 * 1024 + 1) 97)
      , wire
          ( LazyByteString.toStrict
              ( encode
                  ( object
                      [ "scrubber" .= ("old" :: Text)
                      , "payload_sha256" .= ("wrong" :: Text)
                      , "transcript" .= fixtureCanaryTranscript
                      ]
                  )
              )
          )
      ]
      $ \evidence -> canaryPlantRecordingFromEvidence evidence `shouldSatisfy` isLeft

recordingCalls :: ByteString.ByteString -> [Value]
recordingCalls bytes = case must (eitherDecodeStrict' bytes) of
  Object envelope -> case KeyMap.lookup "transcript" envelope of
    Just (Object transcript) -> case KeyMap.lookup "transcriptCalls" transcript of
      Just (Array calls) -> foldr (:) [] calls
      _ -> error "recording calls required"
    _ -> error "recording transcript required"
  _ -> error "recording envelope required"

hasField :: Key -> Value -> Value -> Bool
hasField key expected value = case value of
  Object fields -> KeyMap.lookup key fields == Just expected
  _ -> False

must :: (Show error) => Either error a -> a
must = either (error . show) id

equalRecordedPair :: (Eq a) => [a] -> Bool
equalRecordedPair rows = case rows of
  [first, second] -> first == second
  _ -> False
