{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionFrame (decommissionFrameSuite) where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame
import TestSupport

data TestEntry
  = TestIntent !Text
  | TestObservation !Text
  | TestResult !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decommissionFrameSuite :: SuiteBuilder ()
decommissionFrameSuite =
  describe "Sprint 4.50 decommission receipt frame" $ do
    it "round-trips the genesis frame and a successor through the bounded codec" $ do
      decodeTestFrame 4096 (encodeFrame genesisFrame) `shouldBe` Right genesisFrame
      decodeTestFrame 4096 (encodeFrame successorFrame) `shouldBe` Right successorFrame
    it "refuses an oversized or invalid frame" $ do
      decodeTestFrame 1 (encodeFrame genesisFrame) `shouldBe` Left FrameTooLarge
      decodeTestFrame 4096 "not-a-valid-frame" `shouldBe` Left FrameInvalid
    it "refuses a frame whose stored payload checksum does not match its payload" $ do
      let tampered = genesisFrame {framePayloadChecksum = FrameChecksum "wrong-checksum"}
      decodeTestFrame 4096 (encodeFrame tampered) `shouldBe` Left FrameChecksumMismatch
    it "advances the index and links the previous digest along the chain" $ do
      frameIndex genesisFrame `shouldBe` 0
      framePreviousDigest genesisFrame `shouldBe` genesisPreviousDigest manifest
      frameIndex successorFrame `shouldBe` 1
      framePreviousDigest successorFrame `shouldBe` frameDigest genesisFrame
    it "binds the genesis chain root to the manifest digest" $
      genesisPreviousDigest manifest `shouldNotBe` genesisPreviousDigest otherManifest
    it "gives distinct frames distinct digests" $
      frameDigest genesisFrame `shouldNotBe` frameDigest successorFrame
    it "recomputes a payload checksum deterministically" $
      framePayloadChecksum genesisFrame `shouldBe` payloadChecksum (framePayload genesisFrame)
    it "validates stable node and attempt identifiers" $ do
      mkFrameNodeId "" `shouldBe` Nothing
      mkFrameNodeId "bad\nid" `shouldBe` Nothing
      mkFrameNodeId (Text.replicate 129 "a") `shouldBe` Nothing
      fmap frameNodeIdText (mkFrameNodeId "ses-provider") `shouldBe` Just "ses-provider"
      fmap frameAttemptIdText (mkFrameAttemptId "attempt-1") `shouldBe` Just "attempt-1"
 where
  manifest = FrameDigest "manifest-alpha"
  otherManifest = FrameDigest "manifest-beta"
  nodeId = fromJust (mkFrameNodeId "ses-provider")
  attemptId = fromJust (mkFrameAttemptId "attempt-1")
  genesisFrame =
    appendPayload manifest Nothing nodeId attemptId (TestIntent "destroy ses provider")
  successorFrame =
    appendPayload manifest (Just genesisFrame) nodeId attemptId (TestResult "ses provider absent")

-- | 'decodeFrame' at a fixed payload type, so the error-only fixtures do not need
-- an ambiguous type annotation.
decodeTestFrame :: Int -> ByteString -> Either FrameCodecError (DecommissionFrame TestEntry)
decodeTestFrame = decodeFrame
