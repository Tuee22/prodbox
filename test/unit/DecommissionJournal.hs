{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionJournal (decommissionJournalSuite) where

import Codec.Serialise (Serialise)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Maybe (fromJust)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame
import Prodbox.Lifecycle.Decommission.Journal
import TestSupport

data TestEntry
  = TestIntent !Text
  | TestObservation !Text
  | TestResult !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decommissionJournalSuite :: SuiteBuilder ()
decommissionJournalSuite =
  describe "Sprint 4.50 decommission receipt recovery" $ do
    it "recovers a complete valid chain with nothing to truncate" $ do
      let recovery = recover manifest journal
      recoveredFrames recovery `shouldBe` chain
      recoveredValidBytes recovery `shouldBe` ByteString.length journal
      recoveryOutcome recovery `shouldBe` RecoveryComplete
    it "truncates a torn final record back to the last valid frame" $ do
      let torn = ByteString.take (ByteString.length journal - 3) journal
          recovery = recover manifest torn
      recoveredFrames recovery `shouldBe` [frame0, frame1]
      recoveredValidBytes recovery `shouldBe` ByteString.length (encodeJournal [frame0, frame1])
      recoveryOutcome recovery `shouldBe` RecoveryTruncatableTorn
    it "treats a torn trailing length prefix as recoverable" $ do
      let torn = encodeJournal [frame0, frame1] <> ByteString.take 2 (encodeRecord frame2)
          recovery = recover manifest torn
      recoveredFrames recovery `shouldBe` [frame0, frame1]
      recoveryOutcome recovery `shouldBe` RecoveryTruncatableTorn
    it "refuses a fully written but corrupt final frame" $ do
      let corruptOffset = ByteString.length (encodeJournal [frame0, frame1]) + 4
          recovery = recover manifest (flipByteAt corruptOffset journal)
      recoveredFrames recovery `shouldBe` [frame0, frame1]
      recovery `shouldRefuseAt` 2
    it "refuses interior corruption ahead of valid successors" $ do
      let recovery = recover manifest (flipByteAt 4 journal)
      recoveredFrames recovery `shouldBe` []
      recovery `shouldRefuseAt` 0
    it "refuses a chain/index break" $ do
      let broken = encodeJournal [frame0, frame0]
          recovery = recover manifest broken
      recoveredFrames recovery `shouldBe` [frame0]
      recoveryOutcome recovery `shouldBe` RecoveryRefused (JournalChainDrift 1)
    it "refuses a manifest mismatch at the first frame" $ do
      let recovery = recover otherManifest journal
      recoveredFrames recovery `shouldBe` []
      recoveryOutcome recovery `shouldBe` RecoveryRefused (JournalChainDrift 0)
 where
  manifest = FrameDigest "manifest-alpha"
  otherManifest = FrameDigest "manifest-beta"
  nodeId = fromJust (mkFrameNodeId "ses-provider")
  attemptId = fromJust (mkFrameAttemptId "attempt-1")
  frame0 = appendPayload manifest Nothing nodeId attemptId (TestIntent "destroy")
  frame1 = appendPayload manifest (Just frame0) nodeId attemptId (TestObservation "absent")
  frame2 = appendPayload manifest (Just frame1) nodeId attemptId (TestResult "done")
  chain = [frame0, frame1, frame2]
  journal = encodeJournal chain

recover :: FrameDigest -> ByteString -> ReceiptRecovery TestEntry
recover = recoverReceipt 8192

-- | Assert the recovery refused with a codec error at the given frame index,
-- without pinning the exact 'FrameCodecError' (a flipped byte may surface as an
-- invalid decode or a checksum mismatch).
shouldRefuseAt :: ReceiptRecovery TestEntry -> Word -> Expectation
shouldRefuseAt recovery expectedIndex =
  case recoveryOutcome recovery of
    RecoveryRefused (JournalFrameCodecError index _) -> index `shouldBe` expectedIndex
    other -> expectationFailure ("expected a codec-error refusal, got " <> show other)

flipByteAt :: Int -> ByteString -> ByteString
flipByteAt index bytes =
  ByteString.concat
    [ ByteString.take index bytes
    , ByteString.singleton (ByteString.index bytes index `xor` 0xFF)
    , ByteString.drop (index + 1) bytes
    ]
