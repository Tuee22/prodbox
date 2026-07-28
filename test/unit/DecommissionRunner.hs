{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionRunner (decommissionRunnerSuite) where

import Data.IORef
import Data.Maybe (fromJust, listToMaybe)
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Frame
  ( DecommissionFrame
  , FrameAttemptId
  , FrameDigest
  , FrameNodeId
  , appendPayload
  , framePayload
  , mkFrameAttemptId
  , mkFrameNodeId
  )
import Prodbox.Lifecycle.Decommission.Graph
  ( decommissionTopologicalOrder
  , reportBlocked
  , reportConverged
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , decommissionManifestDigest
  , mkDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( ReceiptReopen (reopenFrames)
  , appendReceiptFrame
  , reopenReceipt
  )
import Prodbox.Lifecycle.Decommission.Runner
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

decommissionRunnerSuite :: SuiteBuilder ()
decommissionRunnerSuite =
  describe "Sprint 4.50 decommission run orchestration" $ do
    it "journals an intent and result per node in topological order and converges" $ do
      entriesRef <- newIORef []
      report <- runDecommission fullInventory [] (recordTo entriesRef) (const (pure (Right ())))
      reportConverged report `shouldBe` True
      entries <- reverse <$> readIORef entriesRef
      entries
        `shouldBe` concatMap
          (\node -> [DecommissionIntent node, DecommissionNodeResult node NodeDestroyed])
          (decommissionTopologicalOrder fullInventory)
    it "skips already-completed nodes without re-running or re-journaling them" $ do
      entriesRef <- newIORef []
      calledRef <- newIORef []
      let completed = [SesConsumerQuiescence, SesProviderStack, SesSmtpIam]
      report <- runDecommission fullInventory completed (recordTo entriesRef) (trackSucceed calledRef)
      reportConverged report `shouldBe` True
      called <- readIORef calledRef
      entries <- readIORef entriesRef
      all (`notElem` called) completed `shouldBe` True
      all (\node -> DecommissionIntent node `notElem` entries) completed `shouldBe` True
    it "journals a failed result and blocks its dependents" $ do
      entriesRef <- newIORef []
      report <- runDecommission fullInventory [] (recordTo entriesRef) (failNode SesProviderStack)
      reportConverged report `shouldBe` False
      entries <- reverse <$> readIORef entriesRef
      (DecommissionNodeResult SesProviderStack (NodeDestroyFailed "injected") `elem` entries)
        `shouldBe` True
      (DecommissionIntent RetainedCustody `notElem` entries) `shouldBe` True
      (RetainedCustody `elem` reportBlocked report) `shouldBe` True
    it "reads only durably destroyed nodes back as completed" $
      completedNodes
        [ DecommissionIntent SesProviderStack
        , DecommissionNodeResult SesProviderStack NodeDestroyed
        , DecommissionIntent TlsRetainedObjects
        , DecommissionNodeResult TlsRetainedObjects (NodeDestroyFailed "boom")
        ]
        `shouldBe` [SesProviderStack]
    it "resumes over a real receipt file, re-running only the failed node and its dependents" $
      withSystemTempDirectory "prodbox-decommission-run" $ \dir -> do
        let path = dir </> "receipt.log"
            manifest = mustRight (mkDecommissionManifest "home" fullInventory)
            digest = decommissionManifestDigest manifest
        -- Run 1: SES provider destroy fails; journal to the real durable receipt.
        lastRef1 <- newIORef Nothing
        _ <- runDecommission fullInventory [] (appendEntry digest path lastRef1) (failNode SesProviderStack)
        -- Restart: recover the receipt and derive the durably-completed set.
        reopen <- reopenReceipt 65536 digest path :: IO (ReceiptReopen DecommissionEntry)
        let recovered = completedNodes (map framePayload (reopenFrames reopen))
        (SesConsumerQuiescence `elem` recovered) `shouldBe` True
        (SesProviderStack `elem` recovered) `shouldBe` False
        -- Run 2: continue the chain, skip completed, everything succeeds.
        lastRef2 <- newIORef (listToMaybe (reverse (reopenFrames reopen)))
        calledRef <- newIORef []
        report <-
          runDecommission
            fullInventory
            recovered
            (appendEntry digest path lastRef2)
            (trackSucceed calledRef)
        reportConverged report `shouldBe` True
        called <- readIORef calledRef
        all (`notElem` called) recovered `shouldBe` True
        (SesProviderStack `elem` called) `shouldBe` True
        (SharedObjectBucket `elem` called) `shouldBe` True
 where
  fullInventory =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , TargetGeneration "vscode"
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    ]

recordTo :: IORef [DecommissionEntry] -> DecommissionEntry -> IO ()
recordTo ref entry = modifyIORef' ref (entry :)

trackSucceed :: IORef [DecommissionNode] -> DecommissionNode -> IO (Either Text ())
trackSucceed ref node = modifyIORef' ref (node :) >> pure (Right ())

failNode :: DecommissionNode -> DecommissionNode -> IO (Either Text ())
failNode target node = pure (if node == target then Left "injected" else Right ())

appendEntry
  :: FrameDigest
  -> FilePath
  -> IORef (Maybe (DecommissionFrame DecommissionEntry))
  -> DecommissionEntry
  -> IO ()
appendEntry digest path lastRef entry = do
  previous <- readIORef lastRef
  let frame = appendPayload digest previous runFrameNodeId runFrameAttemptId entry
  appendReceiptFrame path frame
  writeIORef lastRef (Just frame)

runFrameNodeId :: FrameNodeId
runFrameNodeId = fromJust (mkFrameNodeId "decommission-run")

runFrameAttemptId :: FrameAttemptId
runFrameAttemptId = fromJust (mkFrameAttemptId "attempt-1")

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
