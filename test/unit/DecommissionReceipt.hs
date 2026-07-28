{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionReceipt (decommissionReceiptSuite) where

import Codec.Serialise (Serialise)
import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame
import Prodbox.Lifecycle.Decommission.Journal
import Prodbox.Lifecycle.Decommission.Receipt
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

data TestEntry
  = TestIntent !Text
  | TestObservation !Text
  | TestResult !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decommissionReceiptSuite :: SuiteBuilder ()
decommissionReceiptSuite =
  describe "Sprint 4.50 decommission receipt durable barrier" $ do
    it "appends frames durably and reopens the complete chain" $
      withSystemTempDirectory "prodbox-decommission-receipt" $ \dir -> do
        let path = dir </> "receipt.log"
        mapM_ (appendReceiptFrame path) chain
        reopen <- reopen' path
        reopenFrames reopen `shouldBe` chain
        reopenOutcome reopen `shouldBe` RecoveryComplete
        reopenTruncatedTo reopen `shouldBe` Nothing
    it "truncates a torn tail on reopen and resumes cleanly" $
      withSystemTempDirectory "prodbox-decommission-receipt-torn" $ \dir -> do
        let path = dir </> "receipt.log"
        appendReceiptFrame path frame0
        appendReceiptFrame path frame1
        -- Simulate a crash mid-append of frame2: a partial record lands undurably.
        ByteString.appendFile path (ByteString.take 5 (encodeRecord frame2))
        reopen <- reopen' path
        reopenOutcome reopen `shouldBe` RecoveryTruncatableTorn
        reopenFrames reopen `shouldBe` [frame0, frame1]
        reopenTruncatedTo reopen `shouldSatisfy` isJust
        -- Resume: the real frame2 append now lands after the recovered prefix.
        appendReceiptFrame path frame2
        resumed <- reopen' path
        reopenOutcome resumed `shouldBe` RecoveryComplete
        reopenFrames resumed `shouldBe` chain
    it "refuses a fully written corrupt frame without truncating" $
      withSystemTempDirectory "prodbox-decommission-receipt-corrupt" $ \dir -> do
        let path = dir </> "receipt.log"
        mapM_ (appendReceiptFrame path) [frame0, frame1]
        corruptFileByteAt path (ByteString.length (encodeJournal [frame0]) + 4)
        reopen <- reopen' path
        reopenTruncatedTo reopen `shouldBe` Nothing
        case reopenOutcome reopen of
          RecoveryRefused _ -> pure ()
          other -> expectationFailure ("expected a refusal, got " <> show other)
    it "reopens a missing receipt as an empty complete chain" $
      withSystemTempDirectory "prodbox-decommission-receipt-missing" $ \dir -> do
        reopen <- reopen' (dir </> "absent.log")
        reopenFrames reopen `shouldBe` []
        reopenOutcome reopen `shouldBe` RecoveryComplete
 where
  manifest = FrameDigest "manifest-alpha"
  nodeId = fromJust (mkFrameNodeId "ses-provider")
  attemptId = fromJust (mkFrameAttemptId "attempt-1")
  frame0 = appendPayload manifest Nothing nodeId attemptId (TestIntent "destroy")
  frame1 = appendPayload manifest (Just frame0) nodeId attemptId (TestObservation "absent")
  frame2 = appendPayload manifest (Just frame1) nodeId attemptId (TestResult "done")
  chain = [frame0, frame1, frame2]
  reopen' path = reopenReceipt 8192 manifest path :: IO (ReceiptReopen TestEntry)

corruptFileByteAt :: FilePath -> Int -> IO ()
corruptFileByteAt path index = do
  bytes <- ByteString.readFile path
  let corrupted =
        ByteString.concat
          [ ByteString.take index bytes
          , ByteString.singleton (ByteString.index bytes index `xor` 0xFF)
          , ByteString.drop (index + 1) bytes
          ]
  ByteString.writeFile path corrupted
